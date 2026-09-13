#import <assert.h>
#define NSExtensionMain IridiumTestExtensionMain
#import "../Helper/ExtensionMain.m"
#undef NSExtensionMain

static unsigned calls;
static Class receivedClass;
static BOOL receivedInvocations;
static void validateOtherClass(id decoder, SEL selector, Class cls, id key, BOOL invocations) {
    calls++;
    receivedClass = cls;
    receivedInvocations = invocations;
}
int main(void) {
    @autoreleasepool {
        originalValidation = validateOtherClass;
        for (unsigned flag = 0; flag < 2; flag++) {
            unsigned before = calls;
            validateEndpoint(nil, @selector(description), NSXPCListenerEndpoint.class, @"NS.objects", flag);
            assert(calls == before);
            for (Class cls in @[NSString.class, NSInvocation.class, NSObject.class]) {
                validateEndpoint(nil, @selector(description), cls, @"NS.objects", flag);
                assert(calls == ++before);
                assert(receivedClass == cls && receivedInvocations == flag);
            }
        }
        puts("PASS: endpoint accepted in both invocation modes; other classes retain validation");
    }
}
