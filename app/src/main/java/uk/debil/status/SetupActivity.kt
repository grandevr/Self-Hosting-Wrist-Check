package uk.debil.status

import android.content.Intent
import android.graphics.Bitmap
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.wear.compose.foundation.lazy.TransformingLazyColumn
import androidx.wear.compose.foundation.lazy.TransformingLazyColumnScope
import androidx.wear.compose.foundation.lazy.rememberTransformingLazyColumnState
import androidx.wear.compose.material3.AppScaffold
import androidx.wear.compose.material3.Button
import androidx.wear.compose.material3.CircularProgressIndicator
import androidx.wear.compose.material3.EdgeButton
import androidx.wear.compose.material3.EdgeButtonSize
import androidx.wear.compose.material3.FilledTonalButton
import androidx.wear.compose.material3.Icon
import androidx.wear.compose.material3.ListHeader
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.ScreenScaffold
import androidx.wear.compose.material3.SurfaceTransformation
import androidx.wear.compose.material3.Text
import androidx.wear.compose.material3.lazy.TransformationSpec
import androidx.wear.compose.material3.lazy.rememberTransformationSpec
import androidx.wear.compose.material3.lazy.transformedHeight
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import java.net.Inet4Address
import java.net.InetAddress

/**
 * Setup screen. Brings up the watch's Wi-Fi, starts [SetupServer] on it and shows a QR code,
 * the address and a PIN. Scan or type the address on a phone or computer on the same network and
 * fill in the status URL and token there. "Enter on watch" opens [ManualSetupActivity] instead.
 *
 * The server only runs while this screen is open, and stops after 10 minutes.
 */
class SetupActivity : ComponentActivity() {
    private sealed interface UiState {
        data object Connecting : UiState
        data class Ready(val address: String, val pin: String) : UiState
        data object NoWifi : UiState
        data class Saved(val message: String) : UiState
    }

    private val main = Handler(Looper.getMainLooper())
    private lateinit var cm: ConnectivityManager
    private var wifiCallback: ConnectivityManager.NetworkCallback? = null
    private lateinit var server: SetupServer
    private var address: String? = null
    private var done = false
    private var state by mutableStateOf<UiState>(UiState.Connecting)

    private val manualSetup = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { r ->
        if (r.resultCode == RESULT_OK) {
            done = true
            finish() // saved on the watch: nothing left to do here
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Keep the screen (and with it this page's server) alive while the user types on their phone.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        cm = getSystemService(ConnectivityManager::class.java)
        server = SetupServer(this, object : SetupServer.Listener {
            override fun onSaved(message: String) { main.post { showSaved(message) } }
            override fun onPinChanged(pin: String) { main.post { render() } }
        })

        setContent {
            StatusTheme {
                SetupScreen(
                    state = state,
                    onManual = { manualSetup.launch(Intent(this, ManualSetupActivity::class.java)) },
                    onRetry = {
                        address = null
                        render()
                        requestWifi()
                    },
                )
            }
        }

        render()
        requestWifi()
        main.postDelayed(::timeOut, SERVER_LIFETIME_MS)
    }

    override fun onDestroy() {
        super.onDestroy()
        main.removeCallbacksAndMessages(null)
        server.stop()
        releaseWifi()
    }

    // ---- Wi-Fi ----

    /** Asks Wear OS for Wi-Fi (it is usually off while the phone is connected over Bluetooth). */
    private fun requestWifi() {
        val req = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .build()
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = onWifi(network)
            override fun onLinkPropertiesChanged(network: Network, lp: LinkProperties) = onWifi(network)
            override fun onUnavailable() { main.post { showNoWifi() } }
            override fun onLost(network: Network) {
                main.post {
                    if (done) return@post
                    server.stop()
                    address = null
                    render()
                }
            }
        }
        wifiCallback = cb
        try {
            cm.requestNetwork(req, cb, WIFI_TIMEOUT_MS.toInt())
        } catch (e: Exception) {
            wifiCallback = null
            showNoWifi()
        }
    }

    private fun onWifi(network: Network) {
        val lp = cm.getLinkProperties(network) ?: return
        val ip: InetAddress = lp.linkAddresses
            .map { it.address }
            .firstOrNull { it is Inet4Address && !it.isLoopbackAddress } ?: return
        main.post {
            if (done || address != null) return@post
            try {
                val port = server.start(ip)
                address = "http://" + ip.hostAddress + ":" + port + "/"
                render()
            } catch (e: Exception) {
                showNoWifi()
            }
        }
    }

    private fun releaseWifi() {
        wifiCallback?.let {
            try { cm.unregisterNetworkCallback(it) } catch (_: Exception) {}
        }
        wifiCallback = null
    }

    // ---- state ----

    private fun render() {
        if (done) return
        val a = address
        state = if (a == null) UiState.Connecting else UiState.Ready(a, server.pin())
    }

    private fun showNoWifi() {
        if (done) return
        releaseWifi()
        state = UiState.NoWifi
    }

    private fun showSaved(message: String) {
        done = true
        server.stop()
        releaseWifi()
        Refresh.complication(applicationContext)
        state = UiState.Saved(message)
        main.postDelayed(::finish, 3000)
    }

    private fun timeOut() {
        if (done) return
        server.stop()
        releaseWifi()
        finish()
    }

    @Composable
    private fun SetupScreen(state: UiState, onManual: () -> Unit, onRetry: () -> Unit) {
        val listState = rememberTransformingLazyColumnState()
        val spec = rememberTransformationSpec()
        AppScaffold {
            ScreenScaffold(
                scrollState = listState,
                edgeButton = {
                    if (state !is UiState.Saved) {
                        EdgeButton(onClick = onManual, buttonSize = EdgeButtonSize.Medium) {
                            Icon(painterResource(R.drawable.ic_keyboard), contentDescription = "Enter on watch")
                        }
                    }
                },
            ) { contentPadding ->
                TransformingLazyColumn(
                    state = listState,
                    contentPadding = contentPadding,
                    modifier = Modifier.fillMaxSize(),
                ) {
                    item {
                        ListHeader(Modifier.transformedHeight(this, spec), transformation = SurfaceTransformation(spec)) {
                            Text("Set up")
                        }
                    }
                    when (state) {
                        UiState.Connecting -> connecting(spec)
                        is UiState.Ready -> ready(state, spec)
                        UiState.NoWifi -> noWifi(spec, onRetry, onManual)
                        is UiState.Saved -> saved(state, spec)
                    }
                }
            }
        }
    }

    private fun TransformingLazyColumnScope.connecting(spec: TransformationSpec) {
        item {
            Box(Modifier.fillMaxWidth().padding(8.dp).transformedHeight(this, spec), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(Modifier.size(36.dp))
            }
        }
        item { Title("Connecting to Wi-Fi…", Modifier.transformedHeight(this, spec)) }
        item {
            Caption("The watch needs Wi-Fi on the same network as your phone or computer.",
                Modifier.padding(top = 4.dp).transformedHeight(this, spec))
        }
    }

    private fun TransformingLazyColumnScope.ready(state: UiState.Ready, spec: TransformationSpec) {
        item { Caption("Scan or open on your phone", Modifier.transformedHeight(this, spec)) }
        item {
            val size = (LocalConfiguration.current.screenWidthDp * 0.46f).dp
            val px = with(androidx.compose.ui.platform.LocalDensity.current) { size.roundToPx() }
            val content = state.address + "?pin=" + state.pin
            val bitmap = remember(content, px) { qrBitmap(content, px) }
            Box(Modifier.fillMaxWidth().padding(vertical = 6.dp).transformedHeight(this, spec), contentAlignment = Alignment.Center) {
                Image(
                    bitmap = bitmap.asImageBitmap(),
                    contentDescription = "QR code for the setup page",
                    modifier = Modifier.size(size).clip(RoundedCornerShape(16.dp)).background(Color.White),
                )
            }
        }
        item {
            Title(state.address.removePrefix("http://").removeSuffix("/"), Modifier.transformedHeight(this, spec))
        }
        item {
            Text(
                text = "PIN " + state.pin,
                modifier = Modifier.fillMaxWidth().transformedHeight(this, spec),
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.primary,
                textAlign = TextAlign.Center,
            )
        }
    }

    private fun TransformingLazyColumnScope.noWifi(spec: TransformationSpec, onRetry: () -> Unit, onManual: () -> Unit) {
        item {
            Box(Modifier.fillMaxWidth().transformedHeight(this, spec), contentAlignment = Alignment.Center) {
                Icon(painterResource(R.drawable.ic_wifi_off), contentDescription = null,
                    tint = StatusColors.Slow, modifier = Modifier.size(32.dp))
            }
        }
        item {
            Text("No Wi-Fi", Modifier.fillMaxWidth().transformedHeight(this, spec),
                style = MaterialTheme.typography.titleLarge, color = StatusColors.Slow, textAlign = TextAlign.Center)
        }
        item {
            Caption("Turn on Wi-Fi in the watch's settings and join your home network, then try again. "
                + "Or type the URL and token on the watch.", Modifier.padding(vertical = 4.dp).transformedHeight(this, spec))
        }
        item {
            Button(onClick = onRetry, modifier = Modifier.fillMaxWidth().transformedHeight(this, spec),
                transformation = SurfaceTransformation(spec),
                icon = { Icon(painterResource(R.drawable.ic_refresh), contentDescription = null) },
                label = { Text("Try again") })
        }
        item {
            FilledTonalButton(onClick = onManual, modifier = Modifier.fillMaxWidth().transformedHeight(this, spec),
                transformation = SurfaceTransformation(spec),
                icon = { Icon(painterResource(R.drawable.ic_keyboard), contentDescription = null) },
                label = { Text("Enter on watch") })
        }
    }

    private fun TransformingLazyColumnScope.saved(state: UiState.Saved, spec: TransformationSpec) {
        item {
            Box(Modifier.fillMaxWidth().transformedHeight(this, spec), contentAlignment = Alignment.Center) {
                Icon(painterResource(R.drawable.ic_check), contentDescription = null,
                    tint = StatusColors.Up, modifier = Modifier.size(40.dp))
            }
        }
        item {
            Text("Saved", Modifier.fillMaxWidth().transformedHeight(this, spec),
                style = MaterialTheme.typography.titleLarge, color = StatusColors.Up, textAlign = TextAlign.Center)
        }
        item { Caption(state.message, Modifier.padding(top = 4.dp).transformedHeight(this, spec)) }
    }

    private companion object {
        const val WIFI_TIMEOUT_MS = 20_000L
        const val SERVER_LIFETIME_MS = 10 * 60_000L

        fun qrBitmap(content: String, size: Int): Bitmap = try {
            val hints = mapOf(EncodeHintType.MARGIN to 2)
            val m = QRCodeWriter().encode(content, BarcodeFormat.QR_CODE, size, size, hints)
            val w = m.width
            val h = m.height
            val px = IntArray(w * h)
            for (y in 0 until h) for (x in 0 until w) {
                px[y * w + x] = if (m.get(x, y)) android.graphics.Color.BLACK else android.graphics.Color.WHITE
            }
            Bitmap.createBitmap(px, w, h, Bitmap.Config.ARGB_8888)
        } catch (e: Exception) {
            Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
        }
    }
}

/** Centred title-sized line. */
@Composable
internal fun Title(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text,
        modifier = modifier.fillMaxWidth(),
        style = MaterialTheme.typography.titleMedium,
        fontWeight = FontWeight.Medium,
        color = MaterialTheme.colorScheme.onSurface,
        textAlign = TextAlign.Center,
    )
}
