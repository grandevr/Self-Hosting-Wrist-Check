package uk.debil.status;

import android.content.Context;
import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * A tiny one-page web server that runs on the watch's Wi-Fi address only while the setup screen is
 * open. A phone or computer on the same network opens the page, enters the status URL, the token
 * and the PIN shown on the watch, and the watch tests the values before saving them.
 *
 * - Bound to the Wi-Fi address only, at most 4 connections at once, bodies capped at 8 KB.
 * - Needs the 6-digit PIN shown on the watch; after 5 wrong PINs a new one is drawn.
 * - The token is never logged and never sent back to the browser.
 */
final class SetupServer {
    interface Listener {
        /** Called on the server thread after the values were tested and saved. */
        void onSaved(String message);
        /** Called on the server thread when the PIN changes (too many wrong guesses). */
        void onPinChanged(String pin);
    }

    private static final String TAG = "DebilStatus";
    static final int PREFERRED_PORT = 8765;
    private static final int MAX_BODY = 8 * 1024;
    private static final int MAX_HEADER_BYTES = 8 * 1024;
    private static final int MAX_WRONG_PINS = 5;

    private final Context ctx;
    private final Listener listener;
    private final SecureRandom random = new SecureRandom();
    private volatile ExecutorService workers;
    private volatile ServerSocket socket;
    private volatile String pin;
    private int wrongPins;

    SetupServer(Context ctx, Listener listener) {
        this.ctx = ctx.getApplicationContext();
        this.listener = listener;
        this.pin = newPin();
    }

    String pin() { return pin; }

    /** Starts listening on the given address. Returns the port. */
    int start(InetAddress address) throws Exception {
        ServerSocket ss = new ServerSocket();
        ss.setReuseAddress(true);
        try {
            ss.bind(new InetSocketAddress(address, PREFERRED_PORT));
        } catch (Exception e) {
            ss.bind(new InetSocketAddress(address, 0)); // preferred port busy: any free port
        }
        workers = Executors.newFixedThreadPool(4);
        socket = ss;
        Thread t = new Thread(this::loop, "setup-server");
        t.setDaemon(true);
        t.start();
        return ss.getLocalPort();
    }

    void stop() {
        ServerSocket ss = socket;
        socket = null;
        if (ss != null) {
            try { ss.close(); } catch (Exception ignored) {}
        }
        ExecutorService w = workers;
        if (w != null) w.shutdownNow();
    }

    private void loop() {
        while (true) {
            ServerSocket ss = socket;
            if (ss == null || ss.isClosed()) break;
            ExecutorService pool = workers;
            try {
                Socket client = ss.accept();
                // Own thread per connection: browsers open idle "preconnect" sockets that would
                // otherwise hold up the real request until they time out.
                pool.execute(() -> {
                    try (Socket c = client) {
                        c.setSoTimeout(10_000);
                        handle(c);
                    } catch (Exception e) {
                        Log.w(TAG, "setup request failed: " + e.getClass().getSimpleName());
                    }
                });
            } catch (Exception e) {
                if (socket == null) break;
                Log.w(TAG, "setup accept failed: " + e.getClass().getSimpleName());
            }
        }
    }

    private void handle(Socket client) throws Exception {
        InputStream in = client.getInputStream();
        OutputStream out = client.getOutputStream();

        String head = readHead(in);
        if (head == null) return;
        String[] lines = head.split("\r\n");
        String[] request = lines[0].split(" ");
        if (request.length < 2) { send(out, 400, "text/plain", "Bad request"); return; }
        String method = request[0];
        String target = request[1];
        String path = target.contains("?") ? target.substring(0, target.indexOf('?')) : target;
        Map<String, String> query = target.contains("?")
                ? parseForm(target.substring(target.indexOf('?') + 1)) : new HashMap<>();

        int length = 0;
        for (int i = 1; i < lines.length; i++) {
            String l = lines[i].toLowerCase(Locale.ROOT);
            if (l.startsWith("content-length:")) {
                try { length = Integer.parseInt(l.substring(15).trim()); } catch (NumberFormatException ignored) {}
            }
        }

        if ("GET".equals(method) && "/".equals(path)) {
            send(out, 200, "text/html; charset=utf-8", formPage(query.get("pin"), null));
            return;
        }
        if ("POST".equals(method) && "/".equals(path)) {
            if (length <= 0 || length > MAX_BODY) { send(out, 413, "text/plain", "Too large"); return; }
            byte[] body = readExactly(in, length);
            Map<String, String> form = parseForm(new String(body, StandardCharsets.UTF_8));
            send(out, 200, "text/html; charset=utf-8", save(form));
            return;
        }
        send(out, 404, "text/plain", "Not found");
    }

    /** Validates the form, tests the values against the server and saves them. Returns the page to show. */
    private synchronized String save(Map<String, String> form) {
        String givenPin = trim(form.get("pin"));
        String url = trim(form.get("url"));
        String token = trim(form.get("token"));

        if (!pin.equals(givenPin)) {
            wrongPins++;
            if (wrongPins >= MAX_WRONG_PINS) {
                wrongPins = 0;
                pin = newPin();
                listener.onPinChanged(pin);
                return formPage(null, "Too many wrong PINs. The watch now shows a new one.");
            }
            return formPage(null, "Wrong PIN. Use the 6 digits shown on the watch.");
        }

        String urlError = Config.validateUrl(url);
        if (urlError != null) return formPage(givenPin, urlError);

        boolean keepToken = token.isEmpty();
        if (keepToken) {
            try {
                Config.Creds current = Config.load(ctx);
                if (current != null) token = current.token;
            } catch (Config.UnreadableException ignored) {}
            if (token.isEmpty()) return formPage(givenPin, "Enter the token.");
        }

        StatusFetcher.Result r = StatusFetcher.check(url, token);
        if (!r.ok) return formPage(givenPin, "Not saved. " + r.message);
        try {
            Config.save(ctx, url, token);
        } catch (Exception e) {
            Log.w(TAG, "Couldn't save config: " + e.getClass().getSimpleName());
            return formPage(givenPin, "The values work, but the watch couldn't store them. Try again.");
        }
        listener.onSaved(r.message);
        return donePage(r.message);
    }

    private String newPin() {
        return String.format(Locale.ROOT, "%06d", random.nextInt(1_000_000));
    }

    // ---- HTML ----

    private static final String STYLE = "<style>"
            + "body{font-family:system-ui,sans-serif;background:#111;color:#eee;margin:0;padding:24px 16px;}"
            + "main{max-width:440px;margin:0 auto;}h1{font-size:22px;margin:0 0 4px;}"
            + "p{color:#aaa;line-height:1.4;}label{display:block;margin:18px 0 6px;font-weight:600;}"
            + "input{box-sizing:border-box;width:100%;padding:12px;font-size:16px;border-radius:10px;"
            + "border:1px solid #444;background:#1c1c1c;color:#eee;}"
            + "button{margin-top:24px;width:100%;padding:14px;font-size:17px;border:0;border-radius:10px;"
            + "background:#8ab4f8;color:#111;font-weight:700;}"
            + ".err{background:#3a1d1d;color:#ffb4b4;padding:12px;border-radius:10px;}"
            + ".ok{background:#163222;color:#9fe0b4;padding:12px;border-radius:10px;}"
            + "small{color:#888;}</style>";

    private String formPage(String prefilledPin, String error) {
        String url = Config.currentUrl(ctx);
        boolean hasToken = Config.isConfigured(ctx);
        StringBuilder b = new StringBuilder();
        b.append("<!doctype html><html><head><meta charset=utf-8>")
                .append("<meta name=viewport content='width=device-width,initial-scale=1'>")
                .append("<title>Wrist Check setup</title>").append(STYLE).append("</head><body><main>")
                .append("<h1>Homelab status setup</h1>")
                .append("<p>Enter the address of your <code>status.json</code> and its token. ")
                .append("The watch tests them before saving.</p>");
        if (error != null) b.append("<p class=err>").append(esc(error)).append("</p>");
        b.append("<form method=post action='/' autocomplete=off>")
                .append("<label for=url>Status URL</label>")
                .append("<input id=url name=url type=url inputmode=url required placeholder='https://example.com/health/status.json' value='")
                .append(esc(url)).append("'>")
                .append("<label for=token>Token</label>")
                .append("<input id=token name=token type=password autocomplete=off spellcheck=false")
                .append(hasToken ? " placeholder='Leave empty to keep the current token'>" : " required>")
                .append("<label for=pin>PIN shown on the watch</label>")
                .append("<input id=pin name=pin inputmode=numeric pattern='[0-9]{6}' maxlength=6 required value='")
                .append(prefilledPin == null ? "" : esc(prefilledPin)).append("'>")
                .append("<button type=submit>Test and save</button></form>")
                .append("<p><small>This page is served by the watch itself and only works while its setup ")
                .append("screen is open. The token is sent over your local network to the watch and stored ")
                .append("encrypted there.</small></p></main></body></html>");
        return b.toString();
    }

    private static String donePage(String message) {
        return "<!doctype html><html><head><meta charset=utf-8>"
                + "<meta name=viewport content='width=device-width,initial-scale=1'>"
                + "<title>Wrist Check setup</title>" + STYLE + "</head><body><main>"
                + "<h1>All set</h1><p class=ok>" + esc(message) + "</p>"
                + "<p>You can close this page. Add the <b>Homelab status</b> complication to your watch face "
                + "if you haven't yet.</p></main></body></html>";
    }

    private static String esc(String s) {
        if (s == null) return "";
        return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
                .replace("'", "&#39;").replace("\"", "&quot;");
    }

    // ---- HTTP plumbing ----

    private static String readHead(InputStream in) throws Exception {
        ByteArrayOutputStream buf = new ByteArrayOutputStream();
        int state = 0; // counts \r\n\r\n
        while (buf.size() < MAX_HEADER_BYTES) {
            int c = in.read();
            if (c == -1) return null;
            buf.write(c);
            if ((state == 0 || state == 2) && c == '\r') state++;
            else if ((state == 1 || state == 3) && c == '\n') state++;
            else state = (c == '\r') ? 1 : 0;
            if (state == 4) return buf.toString(StandardCharsets.ISO_8859_1.name());
        }
        return null;
    }

    private static byte[] readExactly(InputStream in, int length) throws Exception {
        byte[] b = new byte[length];
        int off = 0;
        while (off < length) {
            int n = in.read(b, off, length - off);
            if (n == -1) throw new IllegalStateException("short body");
            off += n;
        }
        return b;
    }

    private static Map<String, String> parseForm(String s) {
        Map<String, String> m = new HashMap<>();
        for (String pair : s.split("&")) {
            if (pair.isEmpty()) continue;
            int i = pair.indexOf('=');
            try {
                String k = URLDecoder.decode(i < 0 ? pair : pair.substring(0, i), "UTF-8");
                String v = i < 0 ? "" : URLDecoder.decode(pair.substring(i + 1), "UTF-8");
                m.put(k, v);
            } catch (Exception ignored) {}
        }
        return m;
    }

    private static void send(OutputStream out, int code, String type, String body) throws Exception {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        String reason = code == 200 ? "OK" : code == 404 ? "Not Found" : code == 413 ? "Payload Too Large" : "Bad Request";
        String head = "HTTP/1.1 " + code + " " + reason + "\r\n"
                + "Content-Type: " + type + "\r\n"
                + "Content-Length: " + bytes.length + "\r\n"
                + "Cache-Control: no-store\r\n"
                + "X-Frame-Options: DENY\r\n"
                + "Referrer-Policy: no-referrer\r\n"
                + "Connection: close\r\n\r\n";
        out.write(head.getBytes(StandardCharsets.ISO_8859_1));
        out.write(bytes);
        out.flush();
    }

    private static String trim(String s) { return s == null ? "" : s.trim(); }
}
