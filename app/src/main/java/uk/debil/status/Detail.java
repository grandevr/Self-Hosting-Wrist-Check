package uk.debil.status;

import org.json.JSONArray;
import org.json.JSONObject;

/**
 * One service's detail from the optional "details" field of status.json, for the detail screen.
 * Every field is optional: the server leaves out what Uptime Kuma didn't provide.
 */
final class Detail {
    static final int NONE = Integer.MIN_VALUE;

    final String state;     // "up", "down", "slow", "pending" or ""
    final long since;       // unix seconds the state began, 0 = unknown
    final boolean before;   // the state began before the oldest check the server had
    final String msg;       // Kuma's last message, "" = none
    final int ping;         // latest response time in ms, NONE = none
    final int[] pings;      // recent response times, oldest first, NONE = down / no value
    final double up24;      // 24-hour uptime in percent, NaN = unknown
    final int cert;         // days until the certificate expires, NONE = unknown
    /** The JSON this came from, so the detail screen can be opened with it. */
    final String json;

    private Detail(JSONObject o) {
        json = o.toString();
        state = o.optString("state", "").trim().toLowerCase(java.util.Locale.ROOT);
        since = Math.max(0, o.optLong("since", 0));
        before = o.optBoolean("before", false);
        String m = o.optString("msg", "").trim();
        msg = m.length() > 200 ? m.substring(0, 200) : m;
        ping = number(o, "ping");
        JSONArray arr = o.optJSONArray("pings");
        int n = arr == null ? 0 : Math.min(arr.length(), 200);
        pings = new int[n];
        for (int i = 0; i < n; i++) {
            Object v = arr.opt(i);
            pings[i] = v instanceof Number ? Math.max(0, ((Number) v).intValue()) : NONE;
        }
        double u = o.optDouble("up24", Double.NaN);
        up24 = u >= 0 && u <= 100 ? u : Double.NaN;
        cert = number(o, "cert");
    }

    private static int number(JSONObject o, String key) {
        Object v = o.opt(key);
        return v instanceof Number ? ((Number) v).intValue() : NONE;
    }

    static Detail parse(JSONObject o) {
        return o == null ? null : new Detail(o);
    }

    static Detail parse(String json) {
        try {
            return new Detail(new JSONObject(json));
        } catch (Exception e) {
            return null;
        }
    }

    /** "Sonarr DOWN" -> "Sonarr"; a plain name stays as it is. */
    static String nameOf(String label) {
        if (label.endsWith(" DOWN") || label.endsWith(" SLOW")) return label.substring(0, label.length() - 5);
        return label;
    }
}
