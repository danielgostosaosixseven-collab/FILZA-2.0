#import "exploit/bad_query.h"
#import "exploit/mcm_bridge.h"
#import "kexploit/kexploit_opa334.h"
#import "kexploit/sandbox_escape.h"
#import "kexploit/kutils.h"
#import "helpers/AppIconHelper.h"
#import "helpers/DisplayIdentity.h"
#import "helpers/AirLiftFFI.h"

#import "exploit/worse_query.h"
#import <CoreFoundation/CoreFoundation.h>
typedef struct CF_BRIDGED_TYPE(id) __SecTask *SecTaskRef;
SecTaskRef _Nullable SecTaskCreateFromSelf(CFAllocatorRef _Nullable allocator) CF_RETURNS_RETAINED;
CFTypeRef _Nullable SecTaskCopyValueForEntitlement(SecTaskRef _Nonnull task, CFStringRef _Nonnull entitlement, CFErrorRef _Nullable * _Nullable error) CF_RETURNS_RETAINED;
