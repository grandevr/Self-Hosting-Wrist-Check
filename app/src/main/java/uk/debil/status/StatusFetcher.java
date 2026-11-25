package uk.debil.status;

import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.regex.Pattern;

/** Fetches status.json (bearer token) and turns it into a Status. Blocking: call off the main thread. */
final class StatusFetcher {
    private static final String TAG = "DebilStatus";
    private static final int TIMEOUT_MS = 8000;
    private static final int MAX_BYTES = 16 * 1024;
    private static final Pattern HH_MM = Pattern.compile("\\d{1,2}:\\d{2}");

    private StatusFetcher() {}

    static Status fetch() {
        HttpURLConnection conn = null;
        try {
            conn = (HttpURLConnection) new URL(BuildConfig.STATUS_URL).openConnection();
            conn.setConnectTimeout(TIMEOUT_MS);
            conn.setReadTimeout(TIMEOUT_MS);
            conn.setUseCaches(false);
            conn.setRequestProperty("Authorization", "Bearer " + BuildConfig.STATUS_TOKEN);
            conn.setRequestProperty("Accept", "application/json");

            int code = conn.getResponseCode();
            if (code != 200) {
                Log.w(TAG, "status.json returned HTTP " + code);
                return Status.offline();
            }
            return parse(readBody(conn.getInputStream()));
        } catch (Exception e) {
            Log.w(TAG, "status.json fetch failed: " + e.getClass().getSimpleName());
            return Status.offline();
        } finally {
            if (conn != null) conn.disconnect();
        }
    }

    static Status parse(String body) throws Exception {
        JSONObject json = new JSONObject(body);

        long updated = json.optLong("updated", 0);
        long now = System.currentTimeMillis() / 1000;
        String title = json.optString("title", "");
        String checkedAt = HH_MM.matcher(title).matches() ? title : "";

        if (updated > 0 && now - updated > Status.STALE_AFTER_SECONDS) {
            // "SINCE HH:MM" in the watch's local time, from the last "updated" timestamp.
            String since = new SimpleDateFormat("HH:mm", Locale.UK).format(new Date(updated * 1000));
            return Status.stale(since);
        }
        if (json.has("error")) {
            return Status.kumaError(checkedAt);
        }

        List<String> problems = new ArrayList<>();
        JSONArray arr = json.optJSONArray("problems");
        if (arr != null) {
            for (int i = 0; i < arr.length(); i++) {
                String p = arr.optString(i, "").trim();
                if (!p.isEmpty()) problems.add(p);
            }
        }
        if (problems.isEmpty()) {
            return Status.ok(checkedAt);
        }
        return Status.problems(problems, checkedAt);
    }

    private static String readBody(InputStream in) throws Exception {
        try (InputStream is = in; ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buf = new byte[4096];
            int n, total = 0;
            while ((n = is.read(buf)) != -1) {
                total += n;
                if (total > MAX_BYTES) throw new IllegalStateException("status.json too large");
                out.write(buf, 0, n);
            }
            return out.toString(StandardCharsets.UTF_8.name());
        }
    }
}
