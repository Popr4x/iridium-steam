#!/usr/bin/env python3
"""Exercise the production reservation with a constrained/fragmented Mach map."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[4]
source = (root / 'testrepos/Madeira/app/Madeira/Winios/Winios.m').read_text()
function = source[source.index('int winios_reserve_fex_memory(void)'):]
harness = r'''
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
typedef uint64_t vm_address_t;
typedef uint64_t vm_size_t;
typedef int kern_return_t;
typedef int mach_msg_type_number_t;
typedef void *task_info_t;
typedef struct { uint64_t max_address; } task_vm_info_data_t;
#define TASK_VM_INFO_COUNT 1
#define TASK_VM_INFO 1
#define KERN_SUCCESS 0
#define VM_FLAGS_FIXED 0
#define VM_PROT_NONE 0
#define FALSE 0
#define G (1ULL<<30)
static uint64_t ceiling, taken, length;
static int attempts, mode, releases;
static int mach_task_self(void) { return 1; }
static int task_info(int t, int f, task_info_t i, int *n) {
 ((task_vm_info_data_t *)i)->max_address=ceiling; return mode==3 ? 1 : 0;
}
static int vm_allocate(int t, uint64_t *b, uint64_t s, int flags) {
 assert(flags==VM_FLAGS_FIXED);
 assert(*b+s<=ceiling && *b>=4*G);
 assert(!(*b&65535));
 attempts++;
 if(mode==1 || (mode==4 && *b > ceiling-4*G-G/2) || *b < ceiling-(mode==6 ? 64 : 5)*G) return 1;
 taken=*b+s/2; length=s/2; return 0;
}
static int vm_protect(int t,uint64_t b,uint64_t s,int max,int p) {
 assert(b==taken && s==length && p==VM_PROT_NONE && !max);
 return mode==2 ? 1 : 0;
}
static int vm_deallocate(int t,uint64_t b,uint64_t s) { releases++; return 0; }
'''
main = r'''
int main(int argc,char **argv) {
 mode=atoi(argv[1]); ceiling=strtoull(argv[2],0,10)*G;
 int ok=winios_reserve_fex_memory();
 if(mode==1 || mode==2 || mode==3 || ceiling<6*G) {
  assert(!ok); assert(!getenv("WINE_IOS_FEX_ARENA_BASE"));
  if(mode==2) assert(releases>0);
 } else {
  assert(ok); assert(length<=16*G && (mode==6 || length<=2*G));
  assert(strtoull(getenv("WINE_IOS_FEX_ARENA_BASE"),0,16)==taken);
  assert(strtoull(getenv("WINE_IOS_FEX_ARENA_SIZE"),0,16)==length);
  int old=attempts; assert(winios_reserve_fex_memory()); assert(old==attempts);
 }
}
'''
with tempfile.TemporaryDirectory() as tmp:
    src=Path(tmp)/'arena.c'; exe=Path(tmp)/'arena'
    src.write_text(harness+function+main)
    subprocess.run(['cc','-Wall','-Werror',str(src),'-o',str(exe)],check=True)
    for mode, limit in [(0,454),(0,512),(0,5),(1,454),(2,454),(3,454),(4,454),(0,63),(6,512)]:
        subprocess.run([str(exe),str(mode),str(limit)],check=True)
print('Host arena reservation: 9 cases passed')
