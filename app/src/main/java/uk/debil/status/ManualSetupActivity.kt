package uk.debil.status

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.wear.compose.foundation.lazy.TransformingLazyColumn
import androidx.wear.compose.foundation.lazy.rememberTransformingLazyColumnState
import androidx.wear.compose.material3.AppScaffold
import androidx.wear.compose.material3.CircularProgressIndicator
import androidx.wear.compose.material3.EdgeButton
import androidx.wear.compose.material3.EdgeButtonSize
import androidx.wear.compose.material3.Icon
import androidx.wear.compose.material3.ListHeader
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.ScreenScaffold
import androidx.wear.compose.material3.Text
import java.util.concurrent.Executors

/**
 * Fallback setup: type the status URL and token on the watch. The Wear OS keyboard can also take
 * input from the paired phone, which helps with a long token. Tests the values before saving.
 */
class ManualSetupActivity : ComponentActivity() {
    private val main = Handler(Looper.getMainLooper())
    private var url by mutableStateOf("")
    private var token by mutableStateOf("")
    private var hasToken = false
    private var result by mutableStateOf("")
    private var resultColor by mutableStateOf(Color.Unspecified)
    private var busy by mutableStateOf(false)
    private var saved by mutableStateOf(false)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val current = Config.currentUrl(this)
        url = current.ifEmpty { "https://" }
        hasToken = Config.isConfigured(this)

        setContent { StatusTheme { ManualScreen() } }
    }

    override fun onDestroy() {
        super.onDestroy()
        main.removeCallbacksAndMessages(null)
    }

    private fun testAndSave() {
        if (busy || saved) return
        val u = url.trim()
        var t = token.trim()
        Config.validateUrl(u)?.let { showResult(it, StatusColors.Slow); return }
        if (t.isEmpty()) {
            try {
                Config.load(this)?.let { t = it.token }
            } catch (_: Config.UnreadableException) {}
        }
        if (t.isEmpty()) { showResult("Enter the token.", StatusColors.Slow); return }

        val tok = t
        busy = true
        showResult("Testing…", Color.Unspecified)
        EXECUTOR.execute {
            val r = StatusFetcher.check(u, tok)
            var ok = false
            if (r.ok) {
                try {
                    Config.save(applicationContext, u, tok)
                    ok = true
                } catch (_: Exception) {}
            }
            val msg = if (r.ok && !ok) "Couldn't store the values. Try again." else r.message
            main.post {
                busy = false
                if (isFinishing || isDestroyed) return@post
                showResult(if (ok) "Saved. $msg" else msg, if (ok) StatusColors.Up else StatusColors.Slow)
                if (ok) {
                    saved = true
                    Refresh.complication(applicationContext)
                    setResult(RESULT_OK)
                    main.postDelayed(::finish, 2500)
                }
            }
        }
    }

    private fun showResult(text: String, color: Color) {
        result = text
        resultColor = color
    }

    @Composable
    private fun ManualScreen() {
        val listState = rememberTransformingLazyColumnState()
        val focus = LocalFocusManager.current
        AppScaffold {
            ScreenScaffold(
                scrollState = listState,
                edgeButton = {
                    EdgeButton(
                        onClick = { focus.clearFocus(); testAndSave() },
                        buttonSize = EdgeButtonSize.Medium,
                        enabled = !busy && !saved,
                    ) {
                        if (busy) {
                            CircularProgressIndicator(Modifier.size(24.dp))
                        } else {
                            Icon(painterResource(R.drawable.ic_check), contentDescription = "Test and save")
                        }
                    }
                },
            ) { contentPadding ->
                TransformingLazyColumn(
                    state = listState,
                    contentPadding = contentPadding,
                    modifier = Modifier.fillMaxSize(),
                ) {
                    item { ListHeader { Text("Set up on watch") } }
                    item {
                        Field(
                            label = "Status URL",
                            value = url,
                            onValueChange = { url = it },
                            placeholder = "",
                            keyboardType = KeyboardType.Uri,
                            imeAction = ImeAction.Next,
                        )
                    }
                    item {
                        Field(
                            label = "Token",
                            value = token,
                            onValueChange = { token = it },
                            placeholder = if (hasToken) "Keep current" else "",
                            keyboardType = KeyboardType.Ascii,
                            imeAction = ImeAction.Done,
                            onDone = { focus.clearFocus() },
                        )
                    }
                    if (result.isNotEmpty()) {
                        item { Caption(result, Modifier.padding(top = 6.dp), resultColor) }
                    }
                }
            }
        }
    }

    @Composable
    private fun Field(
        label: String,
        value: String,
        onValueChange: (String) -> Unit,
        placeholder: String,
        keyboardType: KeyboardType,
        imeAction: ImeAction,
        onDone: () -> Unit = {},
    ) {
        val colors = MaterialTheme.colorScheme
        Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
            Text(
                label,
                modifier = Modifier.padding(start = 12.dp, bottom = 2.dp),
                style = MaterialTheme.typography.labelSmall,
                color = colors.onSurfaceVariant,
            )
            BasicTextField(
                value = value,
                onValueChange = onValueChange,
                singleLine = true,
                enabled = !busy && !saved,
                textStyle = MaterialTheme.typography.bodyMedium.copy(color = colors.onSurface),
                cursorBrush = SolidColor(colors.primary),
                keyboardOptions = KeyboardOptions(
                    keyboardType = keyboardType,
                    imeAction = imeAction,
                    autoCorrectEnabled = false,
                ),
                keyboardActions = KeyboardActions(onDone = { onDone() }),
                modifier = Modifier.fillMaxWidth(),
                decorationBox = { inner ->
                    Box(
                        Modifier
                            .fillMaxWidth()
                            .background(colors.surfaceContainer, RoundedCornerShape(50))
                            .border(1.dp, colors.outlineVariant, RoundedCornerShape(50))
                            .padding(horizontal = 14.dp, vertical = 12.dp),
                    ) {
                        if (value.isEmpty() && placeholder.isNotEmpty()) {
                            Text(placeholder, style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant)
                        }
                        inner()
                    }
                },
            )
        }
    }

    private companion object {
        val EXECUTOR = Executors.newSingleThreadExecutor()
    }
}
