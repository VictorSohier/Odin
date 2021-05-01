//+private
//+build windows
package testing

import win32 "core:sys/windows"
import "core:runtime"
import "core:fmt"
import "intrinsics"


Sema :: struct {
	count: i32,
}

sema_reset :: proc "contextless" (s: ^Sema) {
	intrinsics.atomic_store(&s.count, 0);
}
sema_wait :: proc "contextless" (s: ^Sema) {
	for {
		original_count := s.count;
		for original_count == 0 {
			win32.WaitOnAddress(
				&s.count,
				&original_count,
				size_of(original_count),
				win32.INFINITE,
			);
			original_count = s.count;
		}
		if original_count == intrinsics.atomic_cxchg(&s.count, original_count-1, original_count) {
			return;
		}
	}
}

sema_post :: proc "contextless" (s: ^Sema, count := 1) {
	intrinsics.atomic_add(&s.count, i32(count));
	if count == 1 {
		win32.WakeByAddressSingle(&s.count);
	} else {
		win32.WakeByAddressAll(&s.count);
	}
}


Thread_Proc :: #type proc(^Thread);

MAX_USER_ARGUMENTS :: 8;

Thread :: struct {
	using specific: Thread_Os_Specific,
	procedure:      Thread_Proc,

	t:       ^T,
	it:      Internal_Test,
	success: bool,

	init_context: Maybe(runtime.Context),

	creation_allocator: runtime.Allocator,
}

Thread_Os_Specific :: struct {
	win32_thread:    win32.HANDLE,
	win32_thread_id: win32.DWORD,
	done: bool, // see note in `is_done`
}

thread_create :: proc(procedure: Thread_Proc) -> ^Thread {
	__windows_thread_entry_proc :: proc "stdcall" (t_: rawptr) -> win32.DWORD {
		t := (^Thread)(t_);
		context = runtime.default_context();
		c := context;
		if ic, ok := t.init_context.?; ok {
			c = ic;
		}
		context = c;

		t.procedure(t);

		if t.init_context == nil {
			if context.temp_allocator.data == &runtime.global_default_temp_allocator_data {
				runtime.default_temp_allocator_destroy(auto_cast context.temp_allocator.data);
			}
		}

		intrinsics.atomic_store(&t.done, true);
		return 0;
	}


	thread := new(Thread);
	if thread == nil {
		return nil;
	}
	thread.creation_allocator = context.allocator;

	win32_thread_id: win32.DWORD;
	win32_thread := win32.CreateThread(nil, 0, __windows_thread_entry_proc, thread, win32.CREATE_SUSPENDED, &win32_thread_id);
	if win32_thread == nil {
		free(thread, thread.creation_allocator);
		return nil;
	}
	thread.procedure       = procedure;
	thread.win32_thread    = win32_thread;
	thread.win32_thread_id = win32_thread_id;
	thread.init_context = context;

	return thread;
}

thread_start :: proc "contextless" (thread: ^Thread) {
	win32.ResumeThread(thread.win32_thread);
}

thread_join_and_destroy :: proc(thread: ^Thread) {
	if thread.win32_thread != win32.INVALID_HANDLE {
		win32.WaitForSingleObject(thread.win32_thread, win32.INFINITE);
		win32.CloseHandle(thread.win32_thread);
		thread.win32_thread = win32.INVALID_HANDLE;
	}
	free(thread, thread.creation_allocator);
}

thread_terminate :: proc "contextless" (thread: ^Thread, exit_code: int) {
	win32.TerminateThread(thread.win32_thread, u32(exit_code));
}




global_threaded_runner_semaphore: Sema;
global_exception_handler: rawptr;
global_current_thread: ^Thread;
global_current_t: ^T;

run_internal_test :: proc(t: ^T, it: Internal_Test) {
	thread := thread_create(proc(thread: ^Thread) {
		exception_handler_proc :: proc "stdcall" (ExceptionInfo: ^win32.EXCEPTION_POINTERS) -> win32.LONG {
			switch ExceptionInfo.ExceptionRecord.ExceptionCode {
			case
				win32.EXCEPTION_DATATYPE_MISALIGNMENT,
				win32.EXCEPTION_BREAKPOINT,
				win32.EXCEPTION_ACCESS_VIOLATION,
				win32.EXCEPTION_ILLEGAL_INSTRUCTION,
				win32.EXCEPTION_ARRAY_BOUNDS_EXCEEDED,
				win32.EXCEPTION_STACK_OVERFLOW:

				sema_post(&global_threaded_runner_semaphore);
				return win32.EXCEPTION_EXECUTE_HANDLER;
			}

			return win32.EXCEPTION_CONTINUE_SEARCH;
		}
		global_exception_handler = win32.AddVectoredExceptionHandler(0, exception_handler_proc);

		context.assertion_failure_proc = proc(prefix, message: string, loc: runtime.Source_Code_Location) {
			errorf(t=global_current_t, format="%s %s", args={prefix, message}, loc=loc);
			intrinsics.debug_trap();
		};

		thread.it.p(thread.t);

		thread.success = true;
		sema_post(&global_threaded_runner_semaphore);
	});

	sema_reset(&global_threaded_runner_semaphore);
	global_current_t = t;

	thread.t = t;
	thread.it = it;
	thread.success = false;

	thread_start(thread);

	sema_wait(&global_threaded_runner_semaphore);
	thread_terminate(thread, int(!thread.success));
	thread_join_and_destroy(thread);

	win32.RemoveVectoredExceptionHandler(global_exception_handler);

	if !thread.success && t.error_count == 0 {
		t.error_count += 1;
	}

	return;
}
