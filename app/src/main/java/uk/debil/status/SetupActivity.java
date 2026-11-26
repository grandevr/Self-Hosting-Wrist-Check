package uk.debil.status;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.net.ConnectivityManager;
import android.net.LinkAddress;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import com.google.zxing.BarcodeFormat;
import com.google.zxing.EncodeHintType;
import com.google.zxing.common.BitMatrix;
import com.google.zxing.qrcode.QRCodeWriter;

import java.net.Inet4Address;
import java.net.InetAddress;
import java.util.HashMap;
import java.util.Map;

/**
 * Setup screen. Brings up the watch's Wi-Fi, starts {@link SetupServer} on it and shows a QR code,
 * the address and a PIN. Scan or type the address on a phone or computer on the same network and
 * fill in the status URL and token there. "Enter on watch" opens {@link ManualSetupActivity} instead.
 *
 * The server only runs while this screen is open, and stops after 10 minutes.
 */
public class SetupActivity extends Activity {
    private static final long WIFI_TIMEOUT_MS = 20_000;
    private static final long SERVER_LIFETIME_MS = 10 * 60_000;
    private static final int GREY = 0xFFAAAAAA;
    private static final int LINK = 0xFF8AB4F8;

    private final Handler main = new Handler(Looper.getMainLooper());
    private ConnectivityManager cm;
    private ConnectivityManager.NetworkCallback wifiCallback;
    private SetupServer server;
    private LinearLayout list;
    private ScrollView scroll;
    private String address;
    private boolean done;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        // Keep the screen (and with it this page's server) alive while the user types on their phone.
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        int screenW = getResources().getDisplayMetrics().widthPixels;
        int side = (int) (screenW * 0.12f);
        int top = (int) (screenW * 0.10f);
        list = new LinearLayout(this);
        list.setOrientation(LinearLayout.VERTICAL);
        list.setGravity(Gravity.CENTER_HORIZONTAL);
        list.setPadding(side, top, side, top * 2);
        scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.addView(list);
        setContentView(scroll);

        cm = getSystemService(ConnectivityManager.class);
        server = new SetupServer(this, new SetupServer.Listener() {
            @Override public void onSaved(String message) { main.post(() -> showSaved(message)); }
            @Override public void onPinChanged(String pin) { main.post(() -> render()); }
        });

        render();
        requestWifi();
        main.postDelayed(this::timeOut, SERVER_LIFETIME_MS);
    }

    @Override
    protected void onResume() {
        super.onResume();
        scroll.requestFocus(); // rotating bezel scrolls
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        main.removeCallbacksAndMessages(null);
        server.stop();
        releaseWifi();
    }

    // ---- Wi-Fi ----

    /** Asks Wear OS for Wi-Fi (it is usually off while the phone is connected over Bluetooth). */
    private void requestWifi() {
        NetworkRequest req = new NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .build();
        wifiCallback = new ConnectivityManager.NetworkCallback() {
            @Override public void onAvailable(Network network) { onWifi(network); }
            @Override public void onLinkPropertiesChanged(Network network, LinkProperties lp) { onWifi(network); }
            @Override public void onUnavailable() { main.post(() -> showNoWifi()); }
            @Override public void onLost(Network network) {
                main.post(() -> {
                    if (done) return;
                    server.stop();
                    address = null;
                    render();
                });
            }
        };
        try {
            cm.requestNetwork(req, wifiCallback, (int) WIFI_TIMEOUT_MS);
        } catch (Exception e) {
            wifiCallback = null;
            showNoWifi();
        }
    }

    private void onWifi(Network network) {
        LinkProperties lp = cm.getLinkProperties(network);
        if (lp == null) return;
        InetAddress ip = null;
        for (LinkAddress la : lp.getLinkAddresses()) {
            if (la.getAddress() instanceof Inet4Address && !la.getAddress().isLoopbackAddress()) {
                ip = la.getAddress();
                break;
            }
        }
        if (ip == null) return;
        final InetAddress bindTo = ip;
        main.post(() -> {
            if (done || address != null) return;
            try {
                int port = server.start(bindTo);
                address = "http://" + bindTo.getHostAddress() + ":" + port + "/";
                render();
            } catch (Exception e) {
                showNoWifi();
            }
        });
    }

    private void releaseWifi() {
        if (wifiCallback != null) {
            try { cm.unregisterNetworkCallback(wifiCallback); } catch (Exception ignored) {}
            wifiCallback = null;
        }
    }

    // ---- UI ----

    private void render() {
        if (done) return;
        list.removeAllViews();
        list.addView(label("SET UP", 12, GREY, false));

        if (address == null) {
            list.addView(label("Connecting to Wi-Fi…", 15, Color.WHITE, false));
            list.addView(small("The watch needs Wi-Fi on the same network as your phone or computer."));
        } else {
            list.addView(label("Scan or open on your phone", 14, Color.WHITE, false));
            ImageView qr = new ImageView(this);
            int size = (int) (getResources().getDisplayMetrics().widthPixels * 0.46f);
            qr.setImageBitmap(qrBitmap(address + "?pin=" + server.pin(), size));
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(size, size);
            lp.topMargin = dp(6);
            lp.bottomMargin = dp(6);
            qr.setLayoutParams(lp);
            qr.setContentDescription("QR code for the setup page");
            list.addView(qr);
            list.addView(label(address.replace("http://", "").replaceAll("/$", ""), 15, Color.WHITE, true));
            list.addView(label("PIN " + server.pin(), 15, Color.WHITE, false));
        }

        TextView manual = label("Enter on watch", 15, LINK, true);
        manual.setPadding(dp(16), dp(14), dp(16), dp(8));
        manual.setOnClickListener(v -> openManual());
        list.addView(manual);
    }

    private void showNoWifi() {
        if (done) return;
        releaseWifi();
        list.removeAllViews();
        list.addView(label("SET UP", 12, GREY, false));
        list.addView(label("No Wi-Fi", 18, 0xFFFFC566, true));
        list.addView(small("Turn on Wi-Fi in the watch's settings and join your home network, then try again. "
                + "Or type the URL and token on the watch."));
        TextView retry = label("Try again", 15, LINK, true);
        retry.setPadding(dp(16), dp(12), dp(16), dp(4));
        retry.setOnClickListener(v -> { address = null; render(); requestWifi(); });
        list.addView(retry);
        TextView manual = label("Enter on watch", 15, LINK, true);
        manual.setPadding(dp(16), dp(8), dp(16), dp(8));
        manual.setOnClickListener(v -> openManual());
        list.addView(manual);
    }

    private void showSaved(String message) {
        done = true;
        server.stop();
        releaseWifi();
        Refresh.complication(getApplicationContext());
        list.removeAllViews();
        list.addView(label("SET UP", 12, GREY, false));
        list.addView(label("Saved", 22, 0xFF66DD88, true));
        list.addView(small(message));
        main.postDelayed(this::finish, 3000);
    }

    private static final int REQ_MANUAL = 1;

    private void openManual() {
        startActivityForResult(new Intent(this, ManualSetupActivity.class), REQ_MANUAL);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQ_MANUAL && resultCode == RESULT_OK) {
            done = true;
            finish(); // saved on the watch: nothing left to do here
        }
    }

    private void timeOut() {
        if (done) return;
        server.stop();
        releaseWifi();
        finish();
    }

    private Bitmap qrBitmap(String content, int size) {
        try {
            Map<EncodeHintType, Object> hints = new HashMap<>();
            hints.put(EncodeHintType.MARGIN, 2);
            BitMatrix m = new QRCodeWriter().encode(content, BarcodeFormat.QR_CODE, size, size, hints);
            int w = m.getWidth(), h = m.getHeight();
            int[] px = new int[w * h];
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) px[y * w + x] = m.get(x, y) ? Color.BLACK : Color.WHITE;
            }
            return Bitmap.createBitmap(px, w, h, Bitmap.Config.ARGB_8888);
        } catch (Exception e) {
            return Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888);
        }
    }

    private TextView small(String text) {
        TextView tv = label(text, 13, GREY, false);
        tv.setPadding(0, dp(6), 0, 0);
        return tv;
    }

    private TextView label(String text, float sp, int color, boolean bold) {
        return label(this, text, sp, color, bold);
    }

    static TextView label(Context ctx, String text, float sp, int color, boolean bold) {
        TextView tv = new TextView(ctx);
        tv.setText(text);
        tv.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        tv.setTextColor(color);
        tv.setGravity(Gravity.CENTER_HORIZONTAL);
        tv.setLayoutParams(new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT));
        if (bold) tv.setTypeface(tv.getTypeface(), android.graphics.Typeface.BOLD);
        tv.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_YES);
        return tv;
    }

    private int dp(float v) {
        return (int) TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics());
    }
}
