#ifndef _IOS_SDK_SHIM_MACH_VM_H_
#define _IOS_SDK_SHIM_MACH_VM_H_
/*
 * iOS port: the public iOS SDK ships <mach/mach_vm.h> as an "unsupported"
 * stub, but iOS libSystem DOES export mach_vm_map / mach_vm_remap at runtime.
 * Declare them here (signatures match the macOS header) so the V8 darwin
 * JIT path (mach_vm-based executable memory) can compile against the iOS SDK.
 */
#include <mach/mach_types.h>
#include <mach/memory_object_types.h>
#include <mach/vm_inherit.h>
#include <mach/vm_map.h>
#include <mach/vm_prot.h>
#include <mach/vm_types.h>

__BEGIN_DECLS

kern_return_t mach_vm_map(
    vm_map_t target_task,
    mach_vm_address_t *address,
    mach_vm_size_t size,
    mach_vm_offset_t mask,
    int flags,
    mem_entry_name_port_t object,
    memory_object_offset_t offset,
    boolean_t copy,
    vm_prot_t cur_protection,
    vm_prot_t max_protection,
    vm_inherit_t inheritance);

kern_return_t mach_vm_remap(
    vm_map_t target_task,
    mach_vm_address_t *target_address,
    mach_vm_size_t size,
    mach_vm_offset_t mask,
    int flags,
    vm_map_t src_task,
    mach_vm_address_t src_address,
    boolean_t copy,
    vm_prot_t *cur_protection,
    vm_prot_t *max_protection,
    vm_inherit_t inheritance);

__END_DECLS

#endif /* _IOS_SDK_SHIM_MACH_VM_H_ */
