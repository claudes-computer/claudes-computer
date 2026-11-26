package ccrdnet

import (
	"net/http"
	_ "net/http/pprof"
	"sync"
)

var pprofOnce sync.Once

// StartProfiler serves Go's profiler on 127.0.0.1:16060, for measuring where the TV's CPU goes
// ("adb forward tcp:16060 tcp:16060", then go tool pprof). Only started when the app is launched with
// "am start ... --ez profile true".
func StartProfiler() {
	pprofOnce.Do(func() { go http.ListenAndServe("127.0.0.1:16060", nil) })
}
