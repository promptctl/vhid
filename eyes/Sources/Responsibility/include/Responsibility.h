// libquarantine's responsibility calls, which libSystem exports on every macOS eyes runs on
// but the SDK ships no header for. Declared here so they link like any other call, with
// their types checked. Signatures read off the library's disassembly, not a header.
#include <mach/mach.h>
#include <bsm/audit.h>

typedef struct responsibility_identity *responsibility_identity_t;

// The identity tccd attributes the process holding `token` to; NULL when there is none.
// `flags` must be 0.
responsibility_identity_t responsibility_get_attribution_for_audittoken(const audit_token_t *token, int flags);
// The executable the identity's process was spawned from; owned by the identity.
const char *responsibility_identity_get_binary_path(responsibility_identity_t identity);
void responsibility_identity_release(responsibility_identity_t identity);

// This process's audit token, through task_info and the SDK's own count for it.
static inline kern_return_t responsibility_self_audit_token(audit_token_t *token) {
    mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
    return task_info(mach_task_self(), TASK_AUDIT_TOKEN, (task_info_t)token, &count);
}
