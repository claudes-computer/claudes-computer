// A test tool for Android's Low Power Standby, run on the device as the shell user:
//   CLASSPATH=/data/local/tmp/lps.dex app_process / Lps status | enable true|false | force true|false
//                                                    | policy <identifier> <pkg,pkg,...|-> [allowedReasons]
// It calls the power manager directly (the shell user holds MANAGE_LOW_POWER_STANDBY), which is what a TV's
// Settings app does when an Energy mode is chosen. Used by tools/tv-standby-lab.sh on devices without TV Settings.
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

public class Lps {
    public static void main(String[] a) throws Exception {
        Object binder = Class.forName("android.os.ServiceManager").getMethod("getService", String.class).invoke(null, "power");
        Object pm = Class.forName("android.os.IPowerManager$Stub").getMethod("asInterface", android.os.IBinder.class).invoke(null, binder);
        Class<?> ipm = Class.forName("android.os.IPowerManager");
        Class<?> pol = Class.forName("android.os.IPowerManager$LowPowerStandbyPolicy");
        String cmd = a.length > 0 ? a[0] : "status";
        if (cmd.equals("enable")) ipm.getMethod("setLowPowerStandbyEnabled", boolean.class).invoke(pm, Boolean.parseBoolean(a[1]));
        else if (cmd.equals("force")) ipm.getMethod("forceLowPowerStandbyActive", boolean.class).invoke(pm, Boolean.parseBoolean(a[1]));
        else if (cmd.equals("policy")) {
            Object p = pol.getDeclaredConstructor().newInstance();
            pol.getField("identifier").set(p, a[1]);
            pol.getField("exemptPackages").set(p, new ArrayList<String>(a[2].isEmpty() || a[2].equals("-") ? new ArrayList<String>() : Arrays.asList(a[2].split(","))));
            pol.getField("allowedReasons").setInt(p, a.length > 3 ? Integer.parseInt(a[3]) : 0);
            pol.getField("allowedFeatures").set(p, new ArrayList<String>());
            ipm.getMethod("setLowPowerStandbyPolicy", pol).invoke(pm, p);
        }
        Object p = null;
        try { p = ipm.getMethod("getLowPowerStandbyPolicy").invoke(pm); } catch (Exception e) { }
        System.out.println("supported=" + ipm.getMethod("isLowPowerStandbySupported").invoke(pm)
            + " enabled=" + ipm.getMethod("isLowPowerStandbyEnabled").invoke(pm)
            + " policy=" + (p == null ? "none" : pol.getField("identifier").get(p) + " exempt=" + pol.getField("exemptPackages").get(p)
                + " reasons=" + pol.getField("allowedReasons").get(p)));
    }
}
