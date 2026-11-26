package uk.debil.status;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.inputmethod.EditorInfo;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Fallback setup: type the status URL and token on the watch. The Wear OS keyboard can also take
 * input from the paired phone, which helps with a long token. Tests the values before saving.
 */
public class ManualSetupActivity extends Activity {
    private static final ExecutorService EXECUTOR = Executors.newSingleThreadExecutor();
    private static final int GREY = 0xFFAAAAAA;

    private final Handler main = new Handler(Looper.getMainLooper());
    private EditText url;
    private EditText token;
    private TextView result;
    private TextView save;
    private boolean busy;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        int screenW = getResources().getDisplayMetrics().widthPixels;
        int side = (int) (screenW * 0.12f);
        int top = (int) (screenW * 0.10f);

        LinearLayout list = new LinearLayout(this);
        list.setOrientation(LinearLayout.VERTICAL);
        list.setGravity(Gravity.CENTER_HORIZONTAL);
        list.setPadding(side, top, side, top * 2);
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.addView(list);
        setContentView(scroll);

        list.addView(SetupActivity.label(this, "SET UP ON WATCH", 12, GREY, false));

        list.addView(SetupActivity.label(this, "Status URL", 13, GREY, false));
        url = field(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        String current = Config.currentUrl(this);
        url.setText(current.isEmpty() ? "https://" : current);
        list.addView(url);

        list.addView(SetupActivity.label(this, "Token", 13, GREY, false));
        token = field(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        if (Config.isConfigured(this)) token.setHint("Keep current");
        list.addView(token);

        result = SetupActivity.label(this, "", 13, 0xFFFFC566, false);
        list.addView(result);

        save = SetupActivity.label(this, "Test and save", 15, 0xFF8AB4F8, true);
        save.setPadding(dp(16), dp(12), dp(16), dp(12));
        save.setOnClickListener(v -> testAndSave());
        list.addView(save);
    }

    private EditText field(int inputType) {
        EditText e = new EditText(this);
        e.setInputType(inputType);
        e.setSingleLine(true);
        e.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        e.setTextColor(Color.WHITE);
        e.setHintTextColor(GREY);
        e.setImeOptions(EditorInfo.IME_ACTION_DONE);
        e.setLayoutParams(new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT));
        return e;
    }

    private void testAndSave() {
        if (busy) return;
        final String u = url.getText().toString().trim();
        String t = token.getText().toString().trim();
        String err = Config.validateUrl(u);
        if (err != null) { result.setText(err); return; }
        if (t.isEmpty()) {
            try {
                Config.Creds c = Config.load(this);
                if (c != null) t = c.token;
            } catch (Config.UnreadableException ignored) {}
        }
        if (t.isEmpty()) { result.setText("Enter the token."); return; }

        final String tok = t;
        busy = true;
        result.setTextColor(GREY);
        result.setText("Testing…");
        EXECUTOR.execute(() -> {
            StatusFetcher.Result r = StatusFetcher.check(u, tok);
            boolean saved = false;
            if (r.ok) {
                try {
                    Config.save(getApplicationContext(), u, tok);
                    saved = true;
                } catch (Exception ignored) {}
            }
            final boolean ok = saved;
            final String msg = r.ok && !saved ? "Couldn't store the values. Try again." : r.message;
            main.post(() -> {
                busy = false;
                if (isFinishing() || isDestroyed()) return;
                result.setTextColor(ok ? 0xFF66DD88 : 0xFFFFC566);
                result.setText(ok ? "Saved. " + msg : msg);
                if (ok) {
                    Refresh.complication(getApplicationContext());
                    setResult(RESULT_OK);
                    save.setEnabled(false);
                    main.postDelayed(this::finish, 2500);
                }
            });
        });
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        main.removeCallbacksAndMessages(null);
    }

    private int dp(float v) {
        return (int) TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics());
    }
}
