//
//  Created by Alexander Stepanov on 02/06/16.
//  Copyright © 2016 Alexander Stepanov. All rights reserved.
//

#import "KVOExt.h"
#import <objc/runtime.h>


// Source -> KVOExtObserver -> {keyPath:set} -> KVOExtBinding <- set <- KVOExtHolder <- Listener
//  \            /     \                         /    |    \                             /  /
//   -<- assign -       -------<- weak ----------     v     ---------- assign ->---------  /
//                                                  block                                 /
//                                                       ------------- assign ->----------


// Source release -> KVOExtObserver dealloc -> cleanup
// Listener release -> KVOExtHolder dealloc -> remove bindings from observers -> bindings release

// remove binding from observer -> on_stop_observing if bindings count become 0



// macro used instead method to avoid autorelease
#define OBSERVER(src) (src == nil ? nil : (objc_getAssociatedObject(src, ObserverKey) ?: ({ \
id observer = [[KVOExtObserver alloc] initWithDataSource:src]; \
objc_setAssociatedObject(src, ObserverKey, observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC); \
observer; })))


typedef void(^KVOExtBlock)(id owner, id value);
static KVOExtBlock typedInvoker(const char* argType, id block);

static const void *ObserverKey = &ObserverKey;
static const void *HolderKey = &HolderKey;
static const void *DataContextKey = &DataContextKey;

id _kvoext_source;
NSString* _kvoext_keyPath;
BOOL _kvoext_raiseInitial;
const char* _kvoext_argType;
id _kvoext_groupKey;


#pragma mark - interfaces

@interface KVOExtBinding : NSObject
{
@public
    id groupKey;
    
    id __weak sourceObserver;
    BOOL isLazy;
    
    id __unsafe_unretained owner;
    KVOExtBlock block;
    NSString* keyPath;
    BOOL raiseInitial;
}
@end

@interface KVOExtObserver : NSObject
{
@public
    id __unsafe_unretained _dataSource;
    NSMutableDictionary* _bindingsDictionary;
    NSMutableDictionary* _stopObservingDictionary;
    NSString* _currentKeyPath;
}
@end

@interface KVOExtHolder : NSObject
{
@public
    NSMutableSet* _bindings;
}
@end



#pragma mark - KVOExtBinding

@implementation KVOExtBinding
@end




#pragma mark - KVOExtObserver

@implementation KVOExtObserver

- (instancetype)initWithDataSource:(id)source {
    self = [super init];
    if (self) {
        _dataSource = source;
        _bindingsDictionary = [NSMutableDictionary new];
        _stopObservingDictionary = [NSMutableDictionary new];
    }
    return self;
}

-(void)addBinding:(KVOExtBinding*)binding {
    NSString* keyPath = binding->keyPath;
    
    NSMutableSet* set = _bindingsDictionary[keyPath];
    BOOL shouldAddObserver = set == nil;
    
    if (shouldAddObserver) {
        set = [NSMutableSet setWithObject:binding];
        _bindingsDictionary[keyPath] = set;
        
        // add observer
        [_dataSource addObserver:self forKeyPath:keyPath options:0 context:NULL];
        
        _currentKeyPath = keyPath;
        [_dataSource didStartObservingKeyPath:keyPath];
        _currentKeyPath = nil;
    } else {
        [set addObject:binding];
    }
    
    // raise initial
    if (binding->raiseInitial) {
        id val = [_dataSource valueForKey:keyPath];
        binding->block(binding->owner, val);
    }
}

-(void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    
    NSMutableSet* set = _bindingsDictionary[keyPath];
    if (set != nil) {
        id val = [_dataSource valueForKey:keyPath];
        
        // _bindingsDictionary may change while iterating
        // temporary retain bindings by additional set
        NSMutableSet* set1 = [set copy];
        
        for (KVOExtBinding* binding in set1) {
            KVOExtBlock block = binding->block; // block will be nil if binding requested to remove
            if (block != nil) {
                binding->block(binding->owner, val);
            }
        }
    }
}

-(void)removeBinding:(KVOExtBinding*)binding {
    NSString* keyPath = binding->keyPath;
    
    // find item with keypath
    NSMutableSet* set = _bindingsDictionary[keyPath];
    [set removeObject:binding];
    
    BOOL shouldRemoveObserver = set.count == 0;
    if (shouldRemoveObserver) {
        [_bindingsDictionary removeObjectForKey:keyPath];
        [self removeObserver:keyPath];
    }
}

-(void)addStopObservingBlock:(id)block {
    if (_currentKeyPath != nil) {
        NSMutableSet* set = _stopObservingDictionary[_currentKeyPath];
        if (set == nil) {
            set = [NSMutableSet set];
            _stopObservingDictionary[_currentKeyPath] = set;
        }
        
        [set addObject:[block copy]];
    }
}

-(void)removeObserver:(NSString*)keyPath {
    // remove observer
    [_dataSource removeObserver:self forKeyPath:keyPath];
    
    NSMutableSet* set = _stopObservingDictionary[keyPath];
    if (set != nil) {
        [_stopObservingDictionary removeObjectForKey:keyPath];
        
        // raise on_stop_observing block
        for (id block in set) { // copy ???
            ((void(^)())block)(_dataSource);
        }
    }
}

// on source released
-(void)dealloc {
    for (NSString* keyPath in _bindingsDictionary) {
        [self removeObserver:keyPath];
    }
}

@end



#pragma mark - KVOExtHolder

@implementation KVOExtHolder

- (instancetype)init
{
    self = [super init];
    if (self) {
        _bindings = [NSMutableSet new];
    }
    return self;
}

-(void)removeGroup:(id)key {
    NSMutableSet* toRemove = [NSMutableSet new];
    for (KVOExtBinding* binding in _bindings) {
        if ([binding->groupKey isEqual:key]) {
            
            // release block immediately
            // binding itself may be temporary extra retained by observer
            binding->block = nil;
            
            // remove from source
            id observer = binding->sourceObserver; // may be nil
            [observer removeBinding:binding];
            
            [toRemove addObject:binding];
        }
    }
    [_bindings minusSet:toRemove];
}

// on listener released
-(void)dealloc {
    for (KVOExtBinding* binding in _bindings) {
        
        // release block immediately
        // binding itself may be temporary extra retained by observer
        binding->block = nil;
        
        // remove from source
        id observer = binding->sourceObserver; // may be nil
        [observer removeBinding:binding];
    }
}

@end



#pragma mark -  NSObject (KVOExt)

@implementation NSObject (KVOExt)

-(void)set_kvoext_block:(id)block {
    
    // skip if (argType != NULL && source == nil)
    if (_kvoext_argType == NULL || _kvoext_source != nil) {
        
        // isLazy = argType == NULL || source is class
        BOOL isLazy = _kvoext_argType == NULL || _kvoext_source == [_kvoext_source class];
        
        // block
        KVOExtBlock block1 = _kvoext_argType != NULL ? typedInvoker(_kvoext_argType, block) : (KVOExtBlock)block;
        
        // binding
        KVOExtBinding* binding = [KVOExtBinding new];
        binding->groupKey = [_kvoext_groupKey copy];
        binding->owner = self;
        binding->block = [block1 copy];
        binding->keyPath = _kvoext_keyPath; // copy ???
        binding->raiseInitial = _kvoext_raiseInitial;
        binding->isLazy = isLazy;
        //binding->sourceObserver = nil;
        
        // bindings holder
        KVOExtHolder* holder = objc_getAssociatedObject(self, HolderKey);
        if (holder == nil) {
            holder = [KVOExtHolder new];
            objc_setAssociatedObject(self, HolderKey, holder, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [holder->_bindings addObject:binding];
        
        // source observer
        id source = isLazy ? objc_getAssociatedObject(self, DataContextKey) : _kvoext_source;
        KVOExtObserver* observer = OBSERVER(source);    // source may be nil
        binding->sourceObserver = observer;             // observer may be nil
        
        // add binding to source (if observer not nil)
        [observer addBinding:binding];
    }
    
    // clean
    _kvoext_groupKey = nil;
    _kvoext_source = nil;
    _kvoext_keyPath = nil;
    // _kvoext_argType
    // _kvoext_raiseInitial
}

-(void)_kvoext_unbind:(id)key {
    KVOExtHolder* holder = objc_getAssociatedObject(self, HolderKey);
    [holder removeGroup:key];
}

-(instancetype)_kvoext_new { return self; }
+(instancetype)_kvoext_new { return [self new]; }

-(id)_kvoext_source { return self; }
+(id)_kvoext_source { return [self class]; }


#pragma mark - data context

-(id)dataContext {
    return objc_getAssociatedObject(self, DataContextKey);
}

-(void)setDataContext:(id)dataContext {
    
    id oldDataContext = objc_getAssociatedObject(self, DataContextKey);
    if (oldDataContext == dataContext) return;
    
    // change data context
    objc_setAssociatedObject(self, DataContextKey, dataContext, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    // return if no bindings
    KVOExtHolder* holder = objc_getAssociatedObject(self, HolderKey);
    if (holder == nil) return;
    
    
    KVOExtObserver* oldObserver = oldDataContext != nil ? objc_getAssociatedObject(oldDataContext, ObserverKey) : nil;
    KVOExtObserver* observer = OBSERVER(dataContext);
    
    
    // shallow copy
    NSMutableArray* lazyBindings = [NSMutableArray new];
    for (KVOExtBinding* binding in holder->_bindings) {
        if (binding->isLazy) {
            [lazyBindings addObject:binding];
        }
    }
    
    for (KVOExtBinding* binding in lazyBindings) {
        // remove binding from old source
        [oldObserver removeBinding:binding];
        
        // set new source (may be nil)
        binding->sourceObserver = observer;
        
        // add binding to new source
        [observer addBinding:binding]; // may affect holder->_bindings
    }
}


#pragma mark - start/stop observing

-(void)didStartObservingKeyPath:(NSString *)keyPath {}
-(void)set_kvoext_stopObservingBlock:(id)block {
    // self is data source
    KVOExtObserver* observer = objc_getAssociatedObject(self, ObserverKey);
    [observer addStopObservingBlock:block];
}

@end



#pragma mark - block helper

typedef NS_OPTIONS(int, BlockFlags) {
    BlockFlagsHasCopyDisposeHelpers = (1 << 25),
    BlockFlagsHasSignature          = (1 << 30)
};

typedef struct _Block {
    __unused Class isa;
    BlockFlags flags;
    __unused int reserved;
    void (__unused *invoke)(struct _Block *block, ...);
    struct {
        unsigned long int reserved;
        unsigned long int size;
        // requires BlockFlagsHasCopyDisposeHelpers
        void (*copy)(void *dst, const void *src);
        void (*dispose)(const void *);
        // requires BlockFlagsHasSignature
        const char *signature;
        const char *layout;
    } *descriptor;
    // imported variables
} *BlockRef;


static NSMethodSignature* typeSignatureForBlock(id block) {
    BlockRef layout = (__bridge void *)block;
    
    if (layout->flags & BlockFlagsHasSignature) {
        void *desc = layout->descriptor;
        desc += 2 * sizeof(unsigned long int);
        
        if (layout->flags & BlockFlagsHasCopyDisposeHelpers) {
            desc += 2 * sizeof(void *);
        }
        
        if (desc) {
            const char *signature = (*(const char **)desc);
            return [NSMethodSignature signatureWithObjCTypes:signature];
        }
    }
    
    return nil;
}

static KVOExtBlock typedInvoker(const char* argType, id block) {
    
    // Skip const type qualifier.
    if (argType[0] == 'r') {
        argType++;
    }
    
    // id, Class, block
    if (strcmp(argType, @encode(id)) == 0) return block;
    if (strcmp(argType, @encode(Class)) == 0) return block;
    if (strcmp(argType, @encode(void (^)(void))) == 0) return block;
    
#define WRAP(type, selector) \
if (strcmp(argType, @encode(type)) == 0) { \
return ^(id owner, id value){ ((void(^)(id, type))block)(owner, (type)[value selector]); }; \
}
    // 32 bit: @encode(BOOL) -> c (char)
    // 64 bit: @encode(BOOL) -> B (bool)
    
    WRAP(char, charValue); // should be before BOOL
    WRAP(BOOL, boolValue);
    
    WRAP(int, intValue);
    WRAP(short, shortValue);
    WRAP(long, longValue);
    WRAP(long long, longLongValue);
    WRAP(unsigned char, unsignedCharValue);
    WRAP(unsigned int, unsignedIntValue);
    WRAP(unsigned short, unsignedShortValue);
    WRAP(unsigned long, unsignedLongValue);
    WRAP(unsigned long long, unsignedLongLongValue);
    WRAP(float, floatValue);
    WRAP(double, doubleValue);
    WRAP(char*, UTF8String);
    
#undef WRAP
    
    // NSValue
    NSMethodSignature* sig = typeSignatureForBlock(block);
    NSInvocation* invocation = [NSInvocation invocationWithMethodSignature:sig];
    
    return ^(id owner, id value){
        NSCParameterAssert([value isKindOfClass:NSValue.class]);
        
        NSUInteger valueSize = 0;
        NSGetSizeAndAlignment([value objCType], &valueSize, NULL);
        
#if DEBUG
        NSUInteger argSize = 0;
        NSGetSizeAndAlignment(argType, &argSize, NULL);
        NSCAssert(valueSize == argSize, @"Value size does not match argument size: %@", value);
#endif
        
        unsigned char valueBytes[valueSize];
        [value getValue:valueBytes];
        
        [invocation setArgument:&owner atIndex:1];
        [invocation setArgument:valueBytes atIndex:2];
        [invocation invokeWithTarget:block];
    };
}
