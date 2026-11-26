package uk.debil.status;

import android.app.Activity;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Scrollable list of everything that's down or slow, then (if the server sends them) what's up. Opened by tapping the complication (or from
 * the app list). Opening it, or tapping "Refresh", also refreshes the complication right away.
 * Scrolls with touch or the rotating bezel.
 */
public class ProblemsActivity extends Activity {
    private static final ExecutorService EXECUTOR = Executors.newSingleThreadExecutor();
    private static final int GREY = 0xFFAAAAAA;
    private static final int UP_GREEN = 0xFF8FD9A8;

    private final Handler main = new Handler(Looper.getMainLooper());
    private ScrollView scroll;
    private LinearLayout list;
    private boolean loading;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        int screenW = getResources().getDisplayMetrics().widthPixels;
        int side = (int) (screenW * 0.12f);
        int top = (int) (screenW * 0.10f);

        list = new LinearLayout(this);
        list.setOrientation(LinearLayout.VERTICAL);
        list.setGravity(Gravity.CENTER_HORIZONTAL);
        list.setPadding(side, top, side, top * 2);

        scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.setVerticalScrollBarEnabled(true);
        scroll.addView(list);
        setContentView(scroll);

        showMessage("Loading…");
    }

    @Override
    protected void onResume() {
        super.onResume();
        scroll.requestFocus(); // lets the rotating bezel scroll the list
        load();
    }

    private void load() {
        if (loading) return;
        loading = true;
        Refresh.complication(getApplicationContext());
        EXECUTOR.execute(() -> {
            Status s = StatusFetcher.fetch();
            main.post(() -> {
                loading = false;
                if (isFinishing() || isDestroyed()) return;
                show(s);
            });
        });
    }

    private void show(Status s) {
        list.removeAllViews();
        list.addView(label("HOMELAB", 12, GREY, false));
        list.addView(label(s.shortText(), 26, s.color(), true));

        List<String> lines = s.detailLines();
        if (lines.isEmpty() && s.up.isEmpty() && s.kind == Status.Kind.OK) {
            list.addView(label("Everything is up", 15, 0xFFFFFFFF, false));
        }
        for (String line : lines) {
            TextView row = label(line, 16, 0xFFFFFFFF, false);
            row.setPadding(0, dp(6), 0, dp(6));
            list.addView(row);
        }

        if (!s.up.isEmpty()) {
            TextView header = label("UP · " + s.up.size(), 12, GREY, false);
            header.setPadding(0, dp(12), 0, dp(2));
            list.addView(header);
            for (String name : s.up) {
                TextView row = label(name, 15, UP_GREEN, false);
                row.setPadding(0, dp(4), 0, dp(4));
                list.addView(row);
            }
        }

        String footer = s.footer();
        if (!footer.isEmpty()) {
            TextView f = label(footer, 12, GREY, false);
            f.setPadding(0, dp(8), 0, 0);
            list.addView(f);
        }

        TextView refresh = label("Refresh", 15, 0xFF8AB4F8, true);
        refresh.setPadding(dp(16), dp(12), dp(16), dp(12));
        refresh.setOnClickListener(v -> {
            showMessage("Loading…");
            load();
        });
        list.addView(refresh);
        scroll.scrollTo(0, 0);
    }

    private void showMessage(String message) {
        list.removeAllViews();
        list.addView(label("HOMELAB", 12, GREY, false));
        list.addView(label(message, 16, 0xFFFFFFFF, false));
    }

    private TextView label(String text, float sp, int color, boolean bold) {
        TextView tv = new TextView(this);
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
