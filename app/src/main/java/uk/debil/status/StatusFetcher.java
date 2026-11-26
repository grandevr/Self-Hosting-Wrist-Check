package uk.debil.status;

import android.content.Context;
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
    private static final int MAX_BYTES = 32 * 1024;
    private static final Pattern HH_MM = Pattern.compile("\\d{1,2}:\\d{2}");

    private StatusFetcher() {}

    /** Fetches with the configured URL and token. Returns Status.setup() if the app isn't set up. */
    static Status fetch(Context ctx) {
        Config.Creds creds;
        try {
            creds = Config.load(ctx);
        } catch (Config.UnreadableException e) {
            Log.w(TAG, "Stored token couldn't be read");
            return Status.offline();
        }
        if (creds == null) return Status.setup();
        return check(creds.url, creds.token).status;
    }

    /** Result of one request: the Status to show, plus a message for the setup screens. */
    static final class Result {
        final boolean ok;          // got a 200 with a readable status.json
        final Status status;
        final String message;      // human-readable outcome (no secrets)
        Result(boolean ok, Status status, String message) {
            this.ok = ok; this.status = status; this.message = message;
        }
    }

    /** Fetches status.json with the given URL and token. Used both for the complication and to test setup. */
    static Result check(String url, String token) {
        HttpURLConnection conn = null;
        try {
            conn = (HttpURLConnection) new URL(url).openConnection();
            conn.setConnectTimeout(TIMEOUT_MS);
            conn.setReadTimeout(TIMEOUT_MS);
            conn.setUseCaches(false);
            conn.setInstanceFollowRedirects(false); // don't carry the token to another host
            conn.setRequestProperty("Authorization", "Bearer " + token);
            conn.setRequestProperty("Accept", "application/json");

            int code = conn.getResponseCode();
            if (code != 200) {
                Log.w(TAG, "status.json returned HTTP " + code);
                return new Result(false, Status.offline(), httpMessage(code));
            }
            Status s;
            try {
                s = parse(readBody(conn.getInputStream()));
            } catch (Exception e) {
                Log.w(TAG, "status.json unreadable: " + e.getClass().getSimpleName());
                return new Result(false, Status.offline(),
                        "The server answered, but not with a status.json file (or it's over 32 KB).");
            }
            return new Result(true, s, "Connected. The watch shows: " + s.shortText());
        } catch (Exception e) {
            Log.w(TAG, "status.json fetch failed: " + e.getClass().getSimpleName());
            return new Result(false, Status.offline(),
                    "Couldn't reach the server (" + e.getClass().getSimpleName() + ").");
        } finally {
            if (conn != null) conn.disconnect();
        }
    }

    private static String httpMessage(int code) {
        switch (code) {
            case 404: return "The server returned 404. Check the URL, and the token: the server hides the file without the right one.";
            case 401:
            case 403: return "The server refused the token (HTTP " + code + ").";
            case 301:
            case 302:
            case 307:
            case 308: return "The server redirected (HTTP " + code + "). Use the final https:// URL.";
            default: return "The server returned HTTP " + code + ".";
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

        List<String> problems = strings(json.optJSONArray("problems"));
        Status status = problems.isEmpty()
                ? Status.ok(checkedAt)
                : Status.problems(problems, checkedAt);
        // Optional: names of working services. Older status.json without it still works.
        status.up.addAll(strings(json.optJSONArray("up")));
        // Optional: categories, each {"name": ..., "problems": [...], "up": [...]}.
        JSONArray groups = json.optJSONArray("groups");
        if (groups != null) {
            for (int i = 0; i < groups.length(); i++) {
                JSONObject g = groups.optJSONObject(i);
                if (g == null) continue;
                String name = g.optString("name", "").trim();
                Group group = new Group(name.isEmpty() ? "Other" : name);
                group.problems.addAll(strings(g.optJSONArray("problems")));
                group.up.addAll(strings(g.optJSONArray("up")));
                status.groups.add(group);
            }
        }
        return status;
    }

    private static List<String> strings(JSONArray arr) {
        List<String> out = new ArrayList<>();
        if (arr == null) return out;
        for (int i = 0; i < arr.length(); i++) {
            String v = arr.optString(i, "").trim();
            if (!v.isEmpty()) out.add(v);
        }
        return out;
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
