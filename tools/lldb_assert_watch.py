"""lldb helper for ASSERT_WATCH=1 runs of build/mac/dirt3_runner.

When the game's heap assertion fires, the runtime calls ps3_assert_watch_hook(host,
ea) with the corrupt chunk header and parks that thread. This sets a hardware
write watchpoint on those 8 bytes and prints the writing thread's stack (lifted
functions are named func_<guest address>) each time something writes there.

    command script import tools/lldb_assert_watch.py
"""
import lldb

HITS = {'n': 0}


def __lldb_init_module(debugger, internal_dict):
    target = debugger.GetSelectedTarget()
    bp = target.BreakpointCreateByName('ps3_assert_watch_hook')
    bp.SetScriptCallbackFunction('lldb_assert_watch.on_hook')
    print('[lldb] breakpoint on ps3_assert_watch_hook armed')


def on_hook(frame, bp_loc, internal_dict):
    host = frame.FindRegister('x0').GetValueAsUnsigned()
    ea = frame.FindRegister('x1').GetValueAsUnsigned() & 0xFFFFFFFF
    target = frame.GetThread().GetProcess().GetTarget()
    err = lldb.SBError()
    opts = lldb.SBWatchpointOptions()
    opts.SetWatchpointTypeWrite(lldb.eWatchpointWriteTypeOnModify)
    wp = target.WatchpointCreateByAddress(host, 8, opts, err)
    print(f'[lldb] watching guest 0x{ea:08X} (host 0x{host:X}): {err}', flush=True)
    if wp.IsValid():
        frame.GetThread().GetProcess().GetTarget().GetDebugger().HandleCommand(
            f'watchpoint command add -F lldb_assert_watch.on_write {wp.GetID()}')
    return False   # keep running


def on_write(frame, wp, internal_dict):
    HITS['n'] += 1
    thread = frame.GetThread()
    print(f'[lldb] WRITE #{HITS["n"]} to the corrupt chunk by thread '
          f'{thread.GetIndexID()} "{thread.GetName()}"', flush=True)
    for i, f in enumerate(thread):
        if i >= 25:
            break
        print(f'[lldb]   #{i} {f.GetFunctionName()}  {f.GetLineEntry()}', flush=True)
    return HITS['n'] >= 6   # stop the process after a few hits
