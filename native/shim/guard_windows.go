//go:build windows

package main

import (
	"fmt"
	"syscall"
	"unsafe"
)

// guard holds the Job object the child tree lives in. KILL_ON_JOB_CLOSE makes
// tree termination reliable (taskkill /T misses re-parented processes) and
// the optional memory limit makes allocations fail inside the job only —
// Windows has no OOM killer; without a cap a runaway task exhausts commit
// and whichever process allocates next (possibly the BEAM) crashes.
type guard struct {
	job syscall.Handle
}

var (
	createJobObject         = kernel32.NewProc("CreateJobObjectW")
	setInformationJobObject = kernel32.NewProc("SetInformationJobObject")
	assignProcessToJob      = kernel32.NewProc("AssignProcessToJobObject")
	queryInformationJob     = kernel32.NewProc("QueryInformationJobObject")
	terminateJobObject      = kernel32.NewProc("TerminateJobObject")
	psapi                   = syscall.NewLazyDLL("psapi.dll")
	getProcessMemoryInfo    = psapi.NewProc("GetProcessMemoryInfo")
)

const (
	jobObjectBasicAccountingInformationClass = 1
	jobObjectBasicProcessIdList              = 3
	jobObjectExtendedLimitInformationClass   = 9

	jobObjectLimitJobMemory      = 0x00000200
	jobObjectLimitKillOnJobClose = 0x00002000

	processQueryInformation = 0x0400
	processVMRead           = 0x0010
	processSetQuota         = 0x0100
	processTerminate        = 0x0001
)

type ioCounters struct {
	ReadOperationCount, WriteOperationCount, OtherOperationCount uint64
	ReadTransferCount, WriteTransferCount, OtherTransferCount    uint64
}

type jobObjectBasicLimitInformation struct {
	PerProcessUserTimeLimit int64
	PerJobUserTimeLimit     int64
	LimitFlags              uint32
	MinimumWorkingSetSize   uintptr
	MaximumWorkingSetSize   uintptr
	ActiveProcessLimit      uint32
	Affinity                uintptr
	PriorityClass           uint32
	SchedulingClass         uint32
}

type jobObjectExtendedLimitInformation struct {
	BasicLimitInformation jobObjectBasicLimitInformation
	IoInfo                ioCounters
	ProcessMemoryLimit    uintptr
	JobMemoryLimit        uintptr
	PeakProcessMemoryUsed uintptr
	PeakJobMemoryUsed     uintptr
}

type jobObjectBasicAccountingInformation struct {
	TotalUserTime             int64
	TotalKernelTime           int64
	ThisPeriodTotalUserTime   int64
	ThisPeriodTotalKernelTime int64
	TotalPageFaultCount       uint32
	TotalProcesses            uint32
	ActiveProcesses           uint32
	TotalTerminatedProcesses  uint32
}

type processMemoryCounters struct {
	Cb                         uint32
	PageFaultCount             uint32
	PeakWorkingSetSize         uintptr
	WorkingSetSize             uintptr
	QuotaPeakPagedPoolUsage    uintptr
	QuotaPagedPoolUsage        uintptr
	QuotaPeakNonPagedPoolUsage uintptr
	QuotaNonPagedPoolUsage     uintptr
	PagefileUsage              uintptr
	PeakPagefileUsage          uintptr
}

func beforeStart(cfg config) error {
	if cfg.OOMScoreAdj != 0 {
		logf("oom_score_adj has no meaning on Windows; ignored")
	}
	return nil
}

// afterStart puts the child (and everything it spawns) into a fresh Job.
func afterStart(c *child, cfg config) error {
	h, _, err := createJobObject.Call(0, 0)
	if h == 0 {
		return fmt.Errorf("CreateJobObject: %v", err)
	}
	job := syscall.Handle(h)

	var info jobObjectExtendedLimitInformation
	info.BasicLimitInformation.LimitFlags = jobObjectLimitKillOnJobClose
	if cfg.MemoryLimit != 0 {
		info.BasicLimitInformation.LimitFlags |= jobObjectLimitJobMemory
		info.JobMemoryLimit = uintptr(cfg.MemoryLimit)
	}
	r, _, err := setInformationJobObject.Call(uintptr(job), jobObjectExtendedLimitInformationClass,
		uintptr(unsafe.Pointer(&info)), unsafe.Sizeof(info))
	if r == 0 {
		syscall.CloseHandle(job)
		return fmt.Errorf("SetInformationJobObject: %v", err)
	}

	proc, err := syscall.OpenProcess(processSetQuota|processTerminate, false, uint32(c.proc.Process.Pid))
	if err != nil {
		syscall.CloseHandle(job)
		return fmt.Errorf("OpenProcess(%d): %v", c.proc.Process.Pid, err)
	}
	defer syscall.CloseHandle(proc)
	r, _, err = assignProcessToJob.Call(uintptr(job), uintptr(proc))
	if r == 0 {
		syscall.CloseHandle(job)
		return fmt.Errorf("AssignProcessToJobObject: %v", err)
	}
	c.guard.job = job
	return nil
}

// kill terminates every process in the Job — the reliable half of a hard kill.
func (g guard) kill() {
	if g.job != 0 {
		terminateJobObject.Call(uintptr(g.job), 137)
	}
}

// collectStats reads the Job's accounting (CPU) and sums the working sets
// of its live processes (memory).
func collectStats(c *child) treeStats {
	job := c.guard.job
	if job == 0 {
		return treeStats{}
	}
	var stats treeStats

	var acct jobObjectBasicAccountingInformation
	r, _, _ := queryInformationJob.Call(uintptr(job), jobObjectBasicAccountingInformationClass,
		uintptr(unsafe.Pointer(&acct)), unsafe.Sizeof(acct), 0)
	if r != 0 {
		// FILETIME units: 100 ns
		stats.CPUMillis = (acct.TotalUserTime + acct.TotalKernelTime) / 10_000
	}

	// JOBOBJECT_BASIC_PROCESS_ID_LIST: NumberOfAssignedProcesses,
	// NumberOfProcessIdsInList, ProcessIdList[]
	const maxPids = 1024
	buf := make([]uintptr, 2+maxPids)
	r, _, _ = queryInformationJob.Call(uintptr(job), jobObjectBasicProcessIdList,
		uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf))*unsafe.Sizeof(buf[0]), 0)
	if r == 0 {
		return stats
	}
	n := int(buf[1])
	if n > maxPids {
		n = maxPids
	}
	for _, pid := range buf[2 : 2+n] {
		h, err := syscall.OpenProcess(processQueryInformation|processVMRead, false, uint32(pid))
		if err != nil {
			continue
		}
		var mem processMemoryCounters
		mem.Cb = uint32(unsafe.Sizeof(mem))
		if r, _, _ := getProcessMemoryInfo.Call(uintptr(h), uintptr(unsafe.Pointer(&mem)), uintptr(mem.Cb)); r != 0 {
			stats.Processes++
			stats.RSSBytes += uint64(mem.WorkingSetSize)
		}
		syscall.CloseHandle(h)
	}
	return stats
}
