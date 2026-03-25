# AOS Memory Allocator

The AOS Memory Allocator provides dynamic physical page allocation, process address space management, and O(1) continuous virtual page allocation with lazy memory mapping.

## Usage Guide (Syscalls & Exceptions)

User programs interact with the memory allocator through Software Interrupts (SWIs) and implicit exceptions.

### Syscall 2: Allocate Page (`sys_alloc_page`)
- **Registers**: `r7 = 2`
- **Description**: Requests a new 4KB page of memory from the OS.
- **Returns**: `r0` = Virtual address of the newly allocated page, or `0` on failure.
- **Behavior**: Uses O(1) bump-allocation by reading the process's `heap_end` pointer.

### Syscall 3: Free Page (`sys_free_page`)
- **Registers**: `r7 = 3`, `r0` = Virtual address to free
- **Description**: Releases a previously allocated 4KB page.
- **Returns**: `r0` = `0` on success, `-1` on failure.
- **Behavior**: Safely unmaps the memory, removing it from the process descriptor. If the 1MB surrounding section becomes completely empty as a result, the OS automatically frees the underlying L2 translation table to prevent memory leaks.

### Lazy Allocation (Implicit)
Programs do not have to explicitly use Syscall 2 to get memory. If a program attempts to read or write to an unmapped virtual address within the dynamic heap boundary (`[0x00102000, 0x70000000)`), the ARM processor will trigger a Data Abort.
The kernel's Data Abort handler intercepts the crash, securely allocates exactly one 4KB physical page to that virtual address in the background, and seamlessly resumes execution of the faulting instruction.

---

## Kernel Internals: Function Breakdown

The physical allocator manages 131,072 pages (512MB RAM) using a byte-array bitmap (`page_table`).

### Core Physical Allocators
- **`alloc_page`**: Scans the bitmap for the first `0` byte, marks it `1`, and returns the physical address.
- **`free_page`**: Derives the bitmap index from the physical address and sets the byte back to `0`.
- **`alloc_l1_table`**: Scans the bitmap specifically for 4 *contiguous* physical pages to satisfy the ARMv6 hardware requirement that L1 Translation Tables must be 16KB-aligned.
- **`alloc_l2_table`**: Calls `alloc_page` to grab a single 4KB page, maps it via the kernel's higher-half virtual memory, and zeroes out the entire block so no garbage translation entries exist.

### Process Initialization
- **`alloc_process`**:
  Initializes a brand new virtual address space for a process. It allocates an L1 table, maps universal kernel resources (higher-half RAM mapping at `0x80000000` and UART at `0x20200000`), and creates the initial Process Descriptor.
  Crucially, it allocates the first L2 table. Since ARM L2 tables only occupy 1KB of their 4KB page, the kernel repurposes the remaining 3KB of the page to store the **Process Descriptor**, which tracks all physical pages owned by the process. It seeds the process with code, heap, and stack pages, and initializes `heap_end` (used for O(1) allocation) and `next_l2` (used for chaining descriptors).

### Process Runtime Mapping
- **`alloc_process_page`**: 
  The backend for Syscall 2. It reads `heap_end` from the Process Descriptor and increments it by 4KB. It translates this virtual address into L1/L2 indices. If the L1 index points to a missing L2 table (meaning the process crossed a 1MB boundary), it allocates a new L2 table. It then maps a new physical page to the L2 slot and records the physical address in the Process Descriptor.

- **`alloc_specific_page`**:
  The backend for Lazy Allocation. Unlike `alloc_process_page`, it ignores `heap_end`. It accepts a specific virtual address, calculates the correct L1/L2 layout, generates new tables if needed, and maps a physical page precisely at that requested slot.

- **`free_process_page`**:
  The backend for Syscall 3. Validates the virtual address bounds to protect kernel and stack regions. It walks the L1 and L2 tables to find the physical memory, zeroes out the L2 entry, deletes the physical address from the Process Descriptor chain, and returns the physical page to the OS. It then scans the L2 table—if the table is completely empty, it unmaps and frees the L2 table itself. Finally, it flushes the TLB.

### Process Descriptors & Chaining
- **`desc_add` / `desc_remove`**:
  Whenever the OS maps or unmaps a page for a process, it must record the physical address to ensure complete cleanup on program exit. 
  Because an L2 page only has room to track ~766 allocations in its remaining 3KB, `desc_add` is capable of detecting when a descriptor is full. When full, it allocates an entirely new 4KB page strictly for metadata, links it via the `next_l2` pointer, and continues logging allocations. `desc_remove` effortlessly walks this linked list to find and erase physical entries during `sys_free_page`.

### Process Teardown
- **`delete_process`**:
  Triggered when a program calls `sys_exit` (Syscall 1) or accesses fatal illegal memory. Walks the linked list of L2 pages tracking the Process Descriptor. For every logged physical address, it calls `free_page` to return the memory to the system. Finally, it removes the process's existence from the kernel's active `process_list`.
