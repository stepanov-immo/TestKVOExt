//
//  Created by Alexander Stepanov on 02/06/16.
//  Copyright © 2016 Alexander Stepanov. All rights reserved.
//

#import "KVOExt.h"
#import <objc/runtime.h>


id _kvoext_source;
NSString* _kvoext_keyPath;
BOOL _kvoext_raiseInitial;
BOOL _kvoext_isLazy;
const char* _kvoext_argType;
id _kvoext_bindKey;
NSInteger _kvoext_line;


static const void *ObserverKey = &ObserverKey;
static const void *HolderKey = &HolderKey;
static const void *DataContextKey = &DataContextKey;

typedef void(^KVOExtBlock)(id owner, id value);

static KVOExtBlock typedInvoker(const char* argType, id block);


// Source -> Observer -> [keyPath:[]] -> Binding <- [] <- Holder <- Listener


#pragma mark - interfaces

@interface KVOExtBinding : NSObject
{
@public
    id bindKey;
    NSInteger line;
    
    id __weak sourceObserver;
    BOOL isLazy;
    
    id __unsafe_unretained owner;
    KVOExtBlock block;
    NSString* keyPath;
    BOOL raiseInitial;
}
@end

@interface KVOExtObserveItem : NSObject
{
@public
    NSString* keyPath;
    NSMutableArray* bindings;
}
@end

@interface KVOExtObserver : NSObject
{
@public
    id __unsafe_unretained _dataSource;
    NSMutableArray* _observeItems;
    NSMutableDictionary* _stopObservingDictionary;
    NSString* _currentKeyPath;
}
@end

@interface KVOExtHolder : NSObject
{
@public
    NSMutableArray* _bindings;
}
@end



#pragma mark - KVOExtBinding

@implementation KVOExtBinding
@end



#pragma mark - KVOExtObserveItem

@implementation KVOExtObserveItem
@end



#pragma mark - KVOExtObserver

@implementation KVOExtObserver

- (instancetype)initWithDataSource:(id)source {
    self = [super init];
    if (self) {
        _dataSource = source;
        _observeItems = [NSMutableArray array];
        _stopObservingDictionary = [NSMutableDictionary new];
    }
    return self;
}

-(void)addBinding:(KVOExtBinding*)binding {
    NSString* keyPath = binding->keyPath;
    
    // find item with keypath
    KVOExtObserveItem* observeItem = nil;
    for (KVOExtObserveItem* item in _observeItems) {
        if ([item->keyPath isEqualToString:keyPath]) {
            observeItem = item;
            break;
        }
    }
    
    // create new item if not found
    if (observeItem == nil) {
        observeItem = [KVOExtObserveItem new];
        observeItem->keyPath = keyPath;
        observeItem->bindings = [NSMutableArray new];
        [_observeItems addObject:observeItem];
    }
    
    BOOL shouldAddObserver = observeItem->bindings.count == 0;
    
    [observeItem->bindings addObject:binding];
    
    if (shouldAddObserver) {
        // add observer
        [_dataSource addObserver:self forKeyPath:keyPath options:0 context:NULL];
        
        _currentKeyPath = keyPath;
        [_dataSource didStartObservingKeyPath:keyPath];
        _currentKeyPath = nil;
    }
    
    // raise initial
    if (binding->raiseInitial) {
        id val = [_dataSource valueForKey:keyPath];
        binding->block(binding->owner, val);
    }
}

-(void)updateBinding:(KVOExtBinding*)binding  {
    if (binding->raiseInitial) {
        id val = [_dataSource valueForKey:binding->keyPath];
        binding->block(binding->owner, val);
    }
}

-(void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSString *,id> *)change context:(void *)context {
    
    // find item with keypath
    KVOExtObserveItem* observeItem = nil;
    for (KVOExtObserveItem* item in _observeItems) {
        if ([item->keyPath isEqualToString:keyPath]) {
            observeItem = item;
            break;
        }
    }
    
    if (observeItem != nil) {
        
        id val = [_dataSource valueForKey:keyPath];
        
        for (KVOExtBinding* binding in [observeItem->bindings copy]) {
            assert(binding->owner != nil);
            binding->block(binding->owner, val);
        }
    }
}

-(void)removeBinding:(KVOExtBinding*)binding {
    NSString* keyPath = binding->keyPath;
    
    // find item with keypath
    KVOExtObserveItem* observeItem = nil;
    for (KVOExtObserveItem* item in _observeItems) {
        if ([item->keyPath isEqualToString:keyPath]) {
            observeItem = item;
            break;
        }
    }
    
    if (observeItem != nil) {
        if (observeItem->bindings.count > 0) {
            [observeItem->bindings removeObject:binding];
            
            BOOL shouldRemoveObserver = observeItem->bindings.count == 0;
            if (shouldRemoveObserver) {
                // remove observer
                [_dataSource removeObserver:self forKeyPath:keyPath];
                
                [self stopObservingKeyPath:keyPath inDealloc:NO];
            }
        }
    }
}

// on source released
-(void)dealloc {
    for (KVOExtObserveItem* item in _observeItems) {
        if (item->bindings.count > 0) {
            NSString* keyPath = item->keyPath;
            
            // remove observer
            [_dataSource removeObserver:self forKeyPath:keyPath];
            
            [self stopObservingKeyPath:keyPath inDealloc:YES];
        }
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

-(void)stopObservingKeyPath:(NSString*)keyPath inDealloc:(BOOL)inDealloc {
    NSMutableSet* set = _stopObservingDictionary[keyPath];
    [_stopObservingDictionary removeObjectForKey:keyPath];
    
    id src = inDealloc ? nil : _dataSource;
    for (id block in set) { // copy ???
        ((void(^)())block)(src);
    }
}

@end



#pragma mark - KVOExtHolder

@implementation KVOExtHolder

- (instancetype)init
{
    self = [super init];
    if (self) {
        _bindings = [NSMutableArray new];
    }
    return self;
}

-(KVOExtBinding*)findByLine:(NSInteger)line {
    for (KVOExtBinding* binding in _bindings) {
        if (binding->line == line) {
            
            return binding;
        }
    }
    return nil;
}

-(KVOExtBinding*)findByLine:(NSInteger)line andObserver:(id)observer {
    for (KVOExtBinding* binding in _bindings) {
        if (binding->line == line &&
            binding->sourceObserver == observer) {
            return binding;
        }
    }
    return nil;
}

-(KVOExtBinding*)removeBindingForKey:(id)key {
    for (KVOExtBinding* binding in _bindings) {
        if ([binding->bindKey isEqual:key]) {
            BOOL isActive = binding->block != nil;
            if (isActive) {
                binding->block = nil; // unbind
                
                // remove from source
                id observer = binding->sourceObserver; // may be nil
                [observer removeBinding:binding];
            }
            return binding;
        }
    }
    return nil;
}

-(void)removeAll {
    for (KVOExtBinding* binding in _bindings) {
        BOOL isActive = binding->block != nil;
        if (isActive) {
            binding->block = nil; // unbind
            
            // remove from source
            id observer = binding->sourceObserver; // may be nil
            [observer removeBinding:binding];
        }
    }
}

-(void)dealloc {
    [self removeAll];
}

@end



#pragma mark -  NSObject (KVOExt)

@implementation NSObject (KVOExt)

// get or create
-(KVOExtObserver*)_kvoext_observer {
    KVOExtObserver* observer = objc_getAssociatedObject(self, ObserverKey);
    if (observer == nil) {
        observer = [[KVOExtObserver alloc] initWithDataSource:self];
        objc_setAssociatedObject(self, ObserverKey, observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return observer;
}

-(void)set_kvoext_block:(id)block {
    
    // ensure _kvoext_source not nil if not lazy 
    if (_kvoext_isLazy || _kvoext_source != nil) {
        
        id bindKey = [_kvoext_bindKey copy];
        
        // block
        KVOExtBlock block1 = _kvoext_argType != NULL ? typedInvoker(_kvoext_argType, block) : (KVOExtBlock)block;
        block1 = [block1 copy];
        
        
        // bindings holder
        KVOExtHolder* holder = objc_getAssociatedObject(self, HolderKey);
        if (holder == nil) {
            holder = [KVOExtHolder new];
            objc_setAssociatedObject(self, HolderKey, holder, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        
        
        // source observer
        id source = _kvoext_source ?: objc_getAssociatedObject(self, DataContextKey);
        KVOExtObserver* observer = [source _kvoext_observer];


        // find binding
        KVOExtBinding* binding;
        BOOL replaced = NO;
        if (bindKey != nil) {
            binding = [holder removeBindingForKey:bindKey];
        } else {
            if (_kvoext_isLazy) {
                binding = [holder findByLine:_kvoext_line];
                if (binding != nil) {
                    assert(binding->sourceObserver == observer);
                }
            } else {
                assert(observer != nil);
                binding = [holder findByLine:_kvoext_line andObserver:observer];
            }
            replaced = binding != nil;
        }
        
        // create and add to binding list
        if (binding == nil) {
            binding = [KVOExtBinding new];
            [holder->_bindings addObject:binding];
        }
        
        // fill binding
        binding->bindKey = bindKey;
        binding->line = _kvoext_line;
        binding->owner = self;
        binding->block = block1;
        binding->keyPath = _kvoext_keyPath; // copy ???
        binding->raiseInitial = _kvoext_raiseInitial;
        binding->isLazy = _kvoext_isLazy;
        binding->sourceObserver = observer; // may be nil
            
        if (replaced) {
            // raise initial if needed
            [observer updateBinding:binding];
        } else {
            // add binding to source (if not nil)
            [observer addBinding:binding];
        }
        
    }
    
    // clean
    _kvoext_bindKey = nil;
    _kvoext_source = nil;
    _kvoext_keyPath = nil;
    // _kvoext_argType
    // _kvoext_raiseInitial
    // _kvoext_isLazy
    // _kvoext_line
}

-(void)_kvoext_unbind:(id)key {
    KVOExtHolder* holder = objc_getAssociatedObject(self, HolderKey);
    [holder removeBindingForKey:key];
}

-(void)_kvoext_unbind_all {
    KVOExtHolder* holder = objc_getAssociatedObject(self, HolderKey);
    [holder removeAll];
}

-(instancetype)_kvoext_new { return self; }
+(instancetype)_kvoext_new { return [self new]; }

-(id)_kvoext_source { return self; }
+(id)_kvoext_source { return nil; }


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
    KVOExtObserver* observer = [dataContext _kvoext_observer];
    
    
    // shallow copy
    NSMutableArray* lazyBindings = [NSMutableArray new];
    for (KVOExtBinding* binding in holder->_bindings) {
        BOOL isActive = binding->block != nil;
        if (isActive && binding->isLazy) {
            [lazyBindings addObject:binding];
        }
    }
    
    for (KVOExtBinding* binding in lazyBindings) {
        // remove binding from old source
        [oldObserver removeBinding:binding];
        
        // set new source (may be nil)
        binding->sourceObserver = observer;
        
        // add binding to new source
        [observer addBinding:binding];
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
    
    WRAP(BOOL, boolValue);
    WRAP(char, charValue);
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
