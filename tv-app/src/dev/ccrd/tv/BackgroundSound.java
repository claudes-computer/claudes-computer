package dev.ccrd.tv;

import android.app.Activity;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.os.Build;
import android.os.Handler;

/** The speakers, the way a music app holds them: take() claims them for the desktop's sound, and when another app
 *  starts playing (Android's audio focus moves away for good) the given callback runs. KeepPlaying.java is the
 *  service that keeps the app alive meanwhile. */
class BackgroundSound {
    private final Activity act;
    private final Handler handler;
    private final Runnable lost;
    private Object request;
    private final AudioManager.OnAudioFocusChangeListener listener = new AudioManager.OnAudioFocusChangeListener() {
        public void onAudioFocusChange(int change) { if (change == AudioManager.AUDIOFOCUS_LOSS) lost.run(); }
    };

    BackgroundSound(Activity a, Handler h, Runnable onLost) { act = a; handler = h; lost = onLost; }

    void take() {
        AudioManager am = (AudioManager) act.getSystemService(Activity.AUDIO_SERVICE);
        if (am == null) return;
        if (Build.VERSION.SDK_INT >= 26) {
            if (request == null) request = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
                .setOnAudioFocusChangeListener(listener, handler).build();
            am.requestAudioFocus((AudioFocusRequest) request);
        } else {
            am.requestAudioFocus(listener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN);
        }
    }
}
