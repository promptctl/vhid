/// What `launchctl print` said on a real Mac, one capture per standing - verbatim but for
/// the home directory in the development daemon's path, which is renamed.
///
/// Captured 2026-09-24 on macOS 26. The holder is this repo's development daemon, loaded
/// from its plist. The loser is a second job, `ai.promptctl.vhid.doctor-fixture`, whose
/// plist named a service a job under `...doctor-fixture.other` had already been given:
/// its bootstrap exited 0, as the loser's does, and both were booted out after. Kept as
/// launchd printed them, tabs and all, because a fixture tidied by hand is a fixture that
/// agrees with the parser rather than with launchd.
enum LaunchdFixtures {
    /// `launchctl print system/ai.promptctl.vhid.vhidd.dev`, exit 0: a job holding its service.
    static let holding = #"""
        system/ai.promptctl.vhid.vhidd.dev = {
        	active count = 2
        	path = /Library/LaunchDaemons/ai.promptctl.vhid.vhidd.dev.plist
        	type = LaunchDaemon
        	state = running

        	program = /Users/someone/code/vhid/.build/arm64-apple-macosx/debug/vhidd
        	arguments = {
        		/Users/someone/code/vhid/.build/arm64-apple-macosx/debug/vhidd
        		--service
        		ai.promptctl.vhid.vhidd.dev
        	}

        	inherited environment = {
        		DBUS_LAUNCHD_SESSION_BUS_SOCKET => /private/tmp/com.apple.launchd.CcCJ3ofoTQ/unix_domain_listener
        	}

        	default environment = {
        		PATH => /usr/bin:/bin:/usr/sbin:/sbin
        	}

        	environment = {
        		OSLogRateLimit => 64
        		XPC_SERVICE_NAME => ai.promptctl.vhid.vhidd.dev
        	}

        	domain = system
        	minimum runtime = 10
        	exit timeout = 5
        	runs = 1
        	pid = 573
        	immediate reason = semaphore
        	forks = 1
        	execs = 1
        	initialized = 1
        	trampolined = 1
        	started suspended = 0
        	proxy started suspended = 0
        	checked allocations = 0 (queried = 1)
        	checked allocations reason = no host
        	checked allocations flags = 0x0
        	last exit code = (never exited)

        	semaphores = {
        		successful exit => 0
        	}

        	endpoints = {
        		"ai.promptctl.vhid.vhidd.dev" = {
        			port = 0x2b103
        			active = 1
        			managed = 1
        			reset = 0
        			hide = 0
        			watching = 0
        		}
        	}

        	resource coalition = {
        		ID = 513
        		type = resource
        		state = active
        		active count = 1
        		name = ai.promptctl.vhid.vhidd.dev
        	}

        	jetsam coalition = {
        		ID = 514
        		type = jetsam
        		state = active
        		active count = 1
        		name = ai.promptctl.vhid.vhidd.dev
        	}

        	spawn type = daemon (3)
        	jetsam priority = 40
        	jetsam memory limit (active) = (unlimited)
        	jetsam memory limit (inactive) = (unlimited)
        	jetsamproperties category = daemon
        	jetsam thread limit = 32
        	cpumon = default

        	properties = inferred program | system service | managed LWCR | has LWCR | tle system
        }
        """#

    /// `launchctl print system/ai.promptctl.vhid.doctor-fixture`, exit 0: a job loaded
    /// under its label whose service another job holds. Note what is absent - no
    /// `endpoints` block at all - and what is not: the service name, in its environment.
    static let lost = #"""
        system/ai.promptctl.vhid.doctor-fixture = {
        	active count = 0
        	path = /private/tmp/ai.promptctl.vhid.doctor-fixture.plist
        	type = LaunchDaemon
        	state = not running

        	program = /bin/sleep
        	arguments = {
        		/bin/sleep
        		600
        	}

        	inherited environment = {
        		DBUS_LAUNCHD_SESSION_BUS_SOCKET => /private/tmp/com.apple.launchd.CcCJ3ofoTQ/unix_domain_listener
        	}

        	default environment = {
        		PATH => /usr/bin:/bin:/usr/sbin:/sbin
        	}

        	environment = {
        		OSLogRateLimit => 64
        		XPC_SERVICE_NAME => ai.promptctl.vhid.doctor-fixture
        	}

        	domain = system
        	minimum runtime = 10
        	exit timeout = 5
        	runs = 0
        	last exit code = (never exited)

        	spawn type = daemon (3)
        	jetsam priority = 40
        	jetsam memory limit (active) = (unlimited)
        	jetsam memory limit (inactive) = (unlimited)
        	jetsamproperties category = daemon
        	jetsam thread limit = 32
        	cpumon = default

        	properties = inferred program | system service | tle system
        }
        """#

    /// `launchctl print system/ai.promptctl.vhid.doctor-fixture` after the bootout, exit
    /// 113, on stderr: a label launchd has no job under.
    static let noJob = #"""
        Bad request.
        Could not find service "ai.promptctl.vhid.doctor-fixture" in domain for system
        """#
}
