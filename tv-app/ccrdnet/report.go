package ccrdnet

// The TV describing itself to the desktop, so Claude can see what a TV is doing without a laptop or adb:
// the app's version, whether the screen is on and what it shows, what's plugged in, and a picture of the screen.
// Served by ServeKeep (desktop.go) behind its same-user check: GET /tv/report (JSON) and GET /tv/screen (PNG).
// PUT /tv/update takes a new APK: the whole file arrives first, then Android asks the user to install it, so an
// update never cuts the connection it is travelling on. Android only accepts an APK signed with the app's own key.

// TVInfo is implemented by the app (Java, TvInfo.java).
type TVInfo interface {
	// Report returns a JSON object describing the TV right now.
	Report() string
	// Screenshot returns the app's window as a PNG, or nothing if it couldn't take one.
	Screenshot() []byte
	// InstallUpdate hands a downloaded APK to Android, which asks the user to confirm. Returns "" or an error.
	InstallUpdate(path string) string
	// Helper drives the repair helper app (install, pair, code, keys, power, status). Returns "" or a message.
	Helper(action, arg string) string
	// Notice shows a short line on the TV whenever Claude uses the TV itself (its screen, an update, the house
	// check-up), like a camera's light: it doesn't stop anything, it makes it visible.
	Notice(what string)
}

var tvInfo TVInfo

// SetTVInfo is called once by the app at start.
func SetTVInfo(t TVInfo) {
	mu.Lock()
	tvInfo = t
	mu.Unlock()
}

func currentTVInfo() TVInfo {
	mu.Lock()
	defer mu.Unlock()
	return tvInfo
}
