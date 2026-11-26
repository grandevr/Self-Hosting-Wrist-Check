package uk.debil.status

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import androidx.wear.compose.foundation.lazy.TransformingLazyColumn
import androidx.wear.compose.foundation.lazy.rememberTransformingLazyColumnState
import androidx.wear.compose.material3.AppScaffold
import androidx.wear.compose.material3.FilledTonalButton
import androidx.wear.compose.material3.Icon
import androidx.wear.compose.material3.ListHeader
import androidx.wear.compose.material3.ScreenScaffold
import androidx.wear.compose.material3.SurfaceTransformation
import androidx.wear.compose.material3.SwitchButton
import androidx.wear.compose.material3.Text
import androidx.wear.compose.material3.lazy.rememberTransformationSpec
import androidx.wear.compose.material3.lazy.transformedHeight

/**
 * Settings, opened from the bottom of the status list: what the detail screen shows, and a
 * "Setup" button for the status URL and token ([SetupActivity]).
 */
class SettingsActivity : ComponentActivity() {
    private val on = mutableStateMapOf<DetailItem, Boolean>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        for (item in DetailItem.entries) on[item] = item.isOn(this)
        setContent {
            StatusTheme {
                SettingsScreen(
                    isOn = { on[it] ?: true },
                    onToggle = { item, value ->
                        on[item] = value
                        item.set(this, value)
                    },
                    onSetup = { startActivity(Intent(this, SetupActivity::class.java)) },
                )
            }
        }
    }
}

@Composable
private fun SettingsScreen(
    isOn: (DetailItem) -> Boolean,
    onToggle: (DetailItem, Boolean) -> Unit,
    onSetup: () -> Unit,
) {
    val listState = rememberTransformingLazyColumnState()
    val spec = rememberTransformationSpec()
    AppScaffold {
        ScreenScaffold(scrollState = listState) { contentPadding ->
            TransformingLazyColumn(
                state = listState,
                contentPadding = contentPadding,
                modifier = Modifier.fillMaxSize(),
            ) {
                item {
                    ListHeader(Modifier.transformedHeight(this, spec), transformation = SurfaceTransformation(spec)) {
                        Text("Settings")
                    }
                }
                item {
                    FilledTonalButton(
                        onClick = onSetup,
                        modifier = Modifier.fillMaxWidth().transformedHeight(this, spec),
                        transformation = SurfaceTransformation(spec),
                        icon = { Icon(painterResource(R.drawable.ic_settings), contentDescription = null) },
                        label = { Text("Setup") },
                        secondaryLabel = { Text("Status URL and token") },
                    )
                }
                item {
                    ListHeader(Modifier.padding(top = 4.dp).transformedHeight(this, spec), transformation = SurfaceTransformation(spec)) {
                        Text("Service detail")
                    }
                }
                for (item in DetailItem.entries) {
                    item(key = item.key) {
                        val checked = isOn(item)
                        SwitchButton(
                            checked = checked,
                            onCheckedChange = { onToggle(item, it) },
                            modifier = Modifier.fillMaxWidth().transformedHeight(this, spec),
                            transformation = SurfaceTransformation(spec),
                            label = { Text(item.label, maxLines = 2) },
                        )
                    }
                }
                item {
                    Caption(
                        "Tap a service in the list to see its detail. Needs the latest server script.",
                        Modifier.padding(top = 6.dp).transformedHeight(this, spec),
                    )
                }
            }
        }
    }
}
