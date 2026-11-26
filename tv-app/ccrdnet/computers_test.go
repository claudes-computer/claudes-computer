package ccrdnet

import "testing"

func TestIsDesktopName(t *testing.T) {
	for name, want := range map[string]bool{
		"ccrd": true, "CCRD": true, "ccrd-work": true, "ccrd-my-office": true,
		"ccrd-tv": false, "ccrd-tv-1": false, "ccrd-": false, "laptop": false, "ccrdx": false, "": false,
	} {
		if got := IsDesktopName(name); got != want {
			t.Errorf("IsDesktopName(%q) = %v, want %v", name, got, want)
		}
	}
}

func TestSetDesktopRejectsOtherNames(t *testing.T) {
	SetDesktop("ccrd-work")
	if Desktop() != "ccrd-work" {
		t.Fatalf("got %q", Desktop())
	}
	SetDesktop("ccrd-tv") // a TV is never a computer: fall back to the first one
	if Desktop() != "ccrd" {
		t.Fatalf("got %q", Desktop())
	}
}

func TestSameDevice(t *testing.T) {
	for loc, want := range map[string]bool{
		"http://192.168.1.5:49152/desc.xml": true,
		"http://192.168.1.5/desc.xml":       true,
		"http://192.168.1.5@evil.example/x": false,
		"http://192.168.1.5.evil.example/x": false,
		"http://192.168.1.50/desc.xml":      false,
		"https://192.168.1.5/desc.xml":      false,
		"http://user@192.168.1.5/desc.xml":  false,
	} {
		if got := sameDevice(loc, "192.168.1.5"); got != want {
			t.Errorf("sameDevice(%q) = %v, want %v", loc, got, want)
		}
	}
}
