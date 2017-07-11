//
//  KVOExtTests.m
//  TestKVOext
//
//  Created by Alexander Stepanov on 04.07.17.
//  Copyright © 2017 Mediacom. All rights reserved.
//

#import <XCTest/XCTest.h>
#import "KVOExt.h"
#import <objc/runtime.h>


static NSInteger HandleCounter;

static NSMutableDictionary* RefCounters() {
    static NSMutableDictionary* dict = nil;
    if (dict == nil) {
        dict = [NSMutableDictionary new];
    }
    return dict;
}

#define SourceCounter _Counter(@"Source")
#define ListenerCounter _Counter(@"Listener")
#define BindingCounter _Counter(@"KVOExtBinding")
#define _Counter(cls) [RefCounters()[cls] integerValue]

#define _AssertCounter(cls, n) XCTAssertEqual(_Counter(cls), n)
#define AssertSourceCounter(n) XCTAssertEqual(SourceCounter, n)
#define AssertListenerCounter(n) XCTAssertEqual(ListenerCounter, n)
#define AssertBindingCounter(n) XCTAssertEqual(BindingCounter, n)
#define AssertHandleCounter(n) XCTAssertEqual(HandleCounter, n)


static void swizzle(Class cls, SEL origSel, SEL swizSel)
{
    Method origMethod = class_getInstanceMethod(cls, origSel);
    Method swizMethod = class_getInstanceMethod(cls, swizSel);
    assert(origMethod && swizMethod);
    
    class_addMethod(cls, origSel,
                    class_getMethodImplementation(cls, origSel),
                    method_getTypeEncoding(origMethod));
    class_addMethod(cls, swizSel,
                    class_getMethodImplementation(cls, swizSel),
                    method_getTypeEncoding(swizMethod));
    method_exchangeImplementations(class_getInstanceMethod(cls, origSel),
                                   class_getInstanceMethod(cls, swizSel));
}


@implementation NSObject (TestHelper)

+(void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        swizzle([self class], @selector(init), @selector(my_init));
        swizzle([self class], NSSelectorFromString(@"dealloc"), @selector(my_dealloc));
    });
}

-(id)my_init
{
    [self onCreateClass:@"Source"];
    [self onCreateClass:@"Listener"];
    [self onCreateClass:@"KVOExtHolder"];
    [self onCreateClass:@"KVOExtObserver"];
    [self onCreateClass:@"KVOExtBinding"];
    return [self my_init];
}

-(void)my_dealloc {
    [self onRemoveClass:@"Source"];
    [self onRemoveClass:@"Listener"];
    [self onRemoveClass:@"KVOExtHolder"];
    [self onRemoveClass:@"KVOExtObserver"];
    [self onRemoveClass:@"KVOExtBinding"];
    [self my_dealloc];
}

-(void)onCreateClass:(NSString*)clsName {
    if ([self class] == NSClassFromString(clsName)) {
        NSNumber* x = RefCounters()[clsName] ?: @(0);
        NSInteger count = [x integerValue]+1;
        RefCounters()[clsName] = @(count);
        NSLog(@"create class %@, total %@", clsName, @(count));
    }
}

-(void)onRemoveClass:(NSString*)clsName {
    if ([self class] == NSClassFromString(clsName)) {
        NSNumber* x = RefCounters()[clsName] ?: @(0);
        NSInteger count = [x integerValue]-1;
        RefCounters()[clsName] = @(count);
        NSLog(@"remove class %@, total %@", clsName, @(count));
    }
}

@end




@interface Source : NSObject
@property (nonatomic) NSString* str;

@property (nonatomic) NSInteger intVal;
@property (nonatomic) double doubleVal;
@property (nonatomic) CGRect rect;
@property (nonatomic, copy) void(^block)();
@end

@implementation Source

-(void)didStartObservingKeyPath:(NSString *)keyPath
{
    NSLog(@"source start observing: %@", keyPath);
    on_stop_observing {
        NSLog(@"source stop observing: %@, in dealloc: %@", keyPath, @(self == nil));
    };
}

-(void)dealloc
{
    NSLog(@"source dealloc");
}

@end



@interface Listener : NSObject

-(void)bindSource:(Source*)src;
-(void)observeSource:(Source*)src;

-(void)observeSourceWithKey:(Source*)src;
-(void)unbindByKey;
-(void)unbindAll;

-(void)observeAllPropTypes:(Source*)src;

-(void)nestedBindSource:(Source*)src;
-(void)nestedObserveSource:(Source*)src;

-(void)bindSourceClass;
-(void)observeSourceClass;

@end

@interface Listener ()
@property (nonatomic) id key;
@end
@implementation Listener

-(void)bindSource:(Source*)src {
    
    bind(src, str) {
        NSLog(@"-> %@", value);
        HandleCounter++;
    };
}

-(void)observeSource:(Source*)src {
    
    observe(src, str) {
        NSLog(@"-> %@", value);
        HandleCounter++;
    };
}

-(void)observeSourceWithKey:(Source *)src {
    observe(src, str, @"my_key") {
        NSLog(@"-> %@", value);
        HandleCounter++;
    };
}

-(void)unbindByKey {
    unbind(@"my_key");
}

-(void)unbindAll {
    unbind_all();
}

-(void)observeAllPropTypes:(Source *)src {
    observe(src, str) {
        NSLog(@"-> %@", value);
        HandleCounter++;
    };
    observe(src, intVal) {
        NSLog(@"-> %@", @(value));
        HandleCounter++;
    };
    observe(src, doubleVal) {
        NSLog(@"-> %@", @(value));
        HandleCounter++;
    };
    observe(src, rect) {
        NSLog(@"-> %@", NSStringFromCGRect(value));
        HandleCounter++;
    };
    observe(src, block) {
        NSLog(@"-> %@", NSStringFromClass([value class]));
        HandleCounter++;
    };
}

-(void)nestedBindSource:(Source*)src {
    
    bind(src, str) {
        NSLog(@"-> %@", value);
        HandleCounter++;
        
        bind(src, intVal) {
            NSLog(@"-> %@", @(value));
            HandleCounter++;
        };
    };
}

-(void)nestedObserveSource:(Source*)src {
    
    observe(src, str) {
        NSLog(@"-> %@", value);
        HandleCounter++;
        
        observe(src, intVal) {
            NSLog(@"-> %@", @(value));
            HandleCounter++;
        };
    };
}

-(void)bindSourceClass {
    bind(Source, str) {
        NSLog(@"-> %@", value);
        HandleCounter++;
    };
}

-(void)observeSourceClass {
    observe(Source, str) {
        NSLog(@"-> %@", value);
        HandleCounter++;
    };
}

-(void)dealloc {
    NSLog(@"listener dealloc");
}

@end










@interface KVOExtTests : XCTestCase

@end

@implementation KVOExtTests

- (void)setUp {
    [super setUp];
    
    // reset
    HandleCounter = 0;
    [RefCounters() removeAllObjects];
}

- (void)tearDown {
    [super tearDown];
    
    for (NSString* clsName in RefCounters()) {
        NSNumber* count = RefCounters()[clsName];
        XCTAssertEqual([count integerValue], 0);
    }
}

- (void)testBind {
    Source* src = [Source new];
    AssertSourceCounter(1);
    
    Listener* listener = [Listener new];
    AssertBindingCounter(0);
    AssertHandleCounter(0);
    
    [listener bindSource:src];
    AssertBindingCounter(1);
    AssertHandleCounter(1);
    
    src.str = @"hello";
    AssertHandleCounter(2);
    
    src.str = @"hello2";
    AssertHandleCounter(3);
}

- (void)testObserve {
    Source* src = [Source new];
    Listener* listener = [Listener new];
    
    [listener observeSource:src];
    AssertBindingCounter(1);
    AssertHandleCounter(0);
    
    src.str = @"hello";
    AssertHandleCounter(1);
    
    src.str = @"hello2";
    AssertHandleCounter(2);
}

-(void)testPropTypes {
    Source* src = [Source new];
    Listener* listener = [Listener new];
    
    [listener observeAllPropTypes:src];
    AssertBindingCounter(5);
    AssertHandleCounter(0);
    
    src.str = @"hello";
    src.intVal = 2;
    src.doubleVal = 3.4;
    src.rect = CGRectMake(5, 6, 30, 20);
    src.block = ^{ NSLog(@"test"); };
    AssertHandleCounter(5);
}

- (void)testUnbindByKey {
    Source* src = [Source new];
    Listener* listener = [Listener new];
    
    [listener observeSourceWithKey:src];
    
    src.str = @"hello";
    AssertHandleCounter(1);
    
    [listener unbindByKey];
    AssertBindingCounter(1);
    AssertHandleCounter(1);
    
    src.str = @"hello2";
    AssertHandleCounter(1);
}

- (void)testUnbindAll {
    Source* src = [Source new];
    Listener* listener = [Listener new];
    
    [listener observeSourceWithKey:src];
    
    src.str = @"hello";
    AssertHandleCounter(1);
    
    [listener unbindAll];
    AssertBindingCounter(1);
    AssertHandleCounter(1);
    
    src.str = @"hello2";
    AssertHandleCounter(1);
}

- (void)testBindAgain {
    Source* src = [Source new];
    Listener* listener = [Listener new];
    
    [listener bindSource:src];
    AssertBindingCounter(1);
    AssertHandleCounter(1);
    
    [listener bindSource:src];
    AssertBindingCounter(1);
    AssertHandleCounter(2);
    
    src.str = @"hello";
    AssertHandleCounter(3);
}

- (void)testObserveAgain {
    Source* src = [Source new];
    Listener* listener = [Listener new];
    
    [listener observeSource:src];
    AssertBindingCounter(1);
    AssertHandleCounter(0);
    
    [listener observeSource:src];
    AssertBindingCounter(1);
    AssertHandleCounter(0);
    
    src.str = @"hello";
    AssertHandleCounter(1);
}

- (void)testListenerRelease {
    Source* src = [Source new];
    {
        Listener* listener = [Listener new];
        
        [listener observeSource:src];
        AssertBindingCounter(1);
        AssertHandleCounter(0);
        
        src.str = @"hello";
        AssertHandleCounter(1);
        
        AssertListenerCounter(1);
    }
    AssertListenerCounter(0);
    AssertBindingCounter(0);
    
    src.str = @"hello2";
    AssertHandleCounter(1);
}

- (void)testSourceRelease {
    Listener* listener = [Listener new];
    {
        Source* src = [Source new];
        
        [listener observeSource:src];
        AssertBindingCounter(1);
        AssertHandleCounter(0);
        
        src.str = @"hello";
        AssertHandleCounter(1);
        
        AssertSourceCounter(1);
    }
    AssertSourceCounter(0);
    AssertBindingCounter(1);
}

- (void)testNestedBind {
    Source* src = [Source new];
    Listener* listener = [Listener new];
    
    [listener nestedBindSource:src];
    AssertBindingCounter(2);
    AssertHandleCounter(2);
    
    src.str = @"hello";
    AssertBindingCounter(2);
    AssertHandleCounter(4);
    
    src.intVal = 2;
    AssertHandleCounter(5);
    
    [listener unbindAll];
    AssertBindingCounter(2);
    
    src.str = @"hello";
    src.intVal = 2;
    AssertHandleCounter(5);
}

- (void)testNestedObserve {
    Source* src = [Source new];
    Listener* listener = [Listener new];
    
    [listener nestedObserveSource:src];
    AssertBindingCounter(1);
    AssertHandleCounter(0);
    
    src.intVal = 2;
    AssertBindingCounter(1);
    AssertHandleCounter(0);
    
    src.str = @"hello";
    AssertBindingCounter(2);
    AssertHandleCounter(1);
    
    src.intVal = 2;
    AssertBindingCounter(2);
    AssertHandleCounter(2);
    
    [listener unbindAll];
    AssertBindingCounter(2);
    
    src.str = @"hello";
    src.intVal = 2;
    AssertHandleCounter(2);
}

- (void)testSeveralSources {
    Source* src1 = [Source new];
    Source* src2 = [Source new];
    Listener* listener = [Listener new];
    
    [listener bindSource:src1];
    AssertBindingCounter(1);
    AssertHandleCounter(1);
    
    [listener observeSource:src2];
    AssertBindingCounter(2);
    AssertHandleCounter(1);
    
    src1.str = @"hello";
    AssertHandleCounter(2);
    
    src2.str = @"hello";
    AssertHandleCounter(3);
    
    [listener unbindAll];
    AssertBindingCounter(2);
    
    src1.str = @"hello";
    src2.str = @"hello";
    AssertHandleCounter(3);
}

- (void)testSeveralListeners {
    Source* src = [Source new];
    Listener* listener1 = [Listener new];
    Listener* listener2 = [Listener new];
    
    [listener1 observeSource:src];
    AssertBindingCounter(1);
    AssertHandleCounter(0);
    
    [listener2 observeSource:src];
    AssertBindingCounter(2);
    AssertHandleCounter(0);
    
    src.str = @"hello";
    AssertHandleCounter(2);
    
    [listener1 unbindAll];
    
    src.str = @"hello";
    AssertHandleCounter(3);
    
    [listener2 unbindAll];
    
    src.str = @"hello";
    AssertHandleCounter(3);
}

-(void)testDataContextAfterBind {
    Source* src = [Source new];
    Listener* listener = [Listener new];
    
    [listener bindSourceClass];
    AssertBindingCounter(1);
    AssertHandleCounter(0);
    
    src.str = @"hello";
    AssertHandleCounter(0);
    
    listener.dataContext = src;
    AssertHandleCounter(1);
    
    src.str = @"hello";
    AssertHandleCounter(2);
    
    listener.dataContext = nil;
    AssertHandleCounter(2);
    
    src.str = @"hello";
    AssertHandleCounter(2);
}

-(void)testDataContextAfterObserve {
    Source* src = [Source new];
    Listener* listener = [Listener new];
    
    [listener observeSourceClass];
    AssertBindingCounter(1);
    AssertHandleCounter(0);
    
    src.str = @"hello";
    AssertHandleCounter(0);
    
    listener.dataContext = src;
    AssertHandleCounter(0);
    
    src.str = @"hello";
    AssertHandleCounter(1);
    
    listener.dataContext = nil;
    AssertHandleCounter(1);
    
    src.str = @"hello";
    AssertHandleCounter(1);
}

-(void)testDataContextBeforeBind {
    Source* src = [Source new];
    Listener* listener = [Listener new];
    
    listener.dataContext = src;
    AssertBindingCounter(0);
    AssertHandleCounter(0);
    
    [listener bindSourceClass];
    AssertBindingCounter(1);
    AssertHandleCounter(1);
    
    src.str = @"hello";
    AssertHandleCounter(2);
}

-(void)testDataContextBeforeObserve {
    Source* src = [Source new];
    Listener* listener = [Listener new];
    
    listener.dataContext = src;
    AssertBindingCounter(0);
    AssertHandleCounter(0);
    
    [listener observeSourceClass];
    AssertBindingCounter(1);
    AssertHandleCounter(0);
    
    src.str = @"hello";
    AssertHandleCounter(1);
}

-(void)testDataContextChange {
    Source* src1 = [Source new];
    Source* src2 = [Source new];
    Listener* listener = [Listener new];
    
    [listener observeSourceClass];
    listener.dataContext = src1;
    
    src1.str = @"hello";
    AssertHandleCounter(1);
    
    src2.str = @"hello";
    AssertHandleCounter(1);
    
    listener.dataContext = src2;
    
    src1.str = @"hello";
    AssertHandleCounter(1);
    
    src2.str = @"hello";
    AssertHandleCounter(2);
}

-(void)testDataContextUnbind {
    Source* src = [Source new];
    Listener* listener = [Listener new];
    
    [listener observeSourceClass];
    [listener unbindAll];
    
    listener.dataContext = src;
    src.str = @"hello";
    AssertHandleCounter(0);
}

@end