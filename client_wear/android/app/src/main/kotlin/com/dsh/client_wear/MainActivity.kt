package com.dsh.client_wear

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import android.view.MotionEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The rotating crown, turned into scrolling and a tick.
 *
 * A watch with a crown is driven by it: the thumb never leaves the bezel, and a
 * list that ignores the crown reads as broken rather than merely limited.
 * Flutter has no rotary input of its own here, so the crown is read where its
 * motion event arrives and two things are done with it — the scroll offset goes
 * to the running Dart app, and every so often a short vibration answers the
 * turn.
 *
 * The tick follows the system's own crown feedback rather than inventing one:
 * the same private linear-motor effect the stock launcher uses (type 302,
 * strength 2, no loop), reached by reflection because that class is not part of
 * the public SDK. Where the class is absent — a watch from another maker, or a
 * build that hides it — a public VibrationEffect stands in with the duration
 * and amplitude the system's own logs show for that effect (30 ms, amplitude
 * 80).
 */
class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.dsh.client_wear/rotary"

        /** Log tag for the crown path; the stock widget logs its own as CrownAnim. */
        private const val TAG = "CrownTick"

        /** Duration and amplitude of the stand-in effect. */
        private const val FALLBACK_MS = 30L
        private const val FALLBACK_AMPLITUDE = 80

        /** The private effect's own settings, as decompiled from the stock widget. */
        private const val PRIVATE_SERVICE = "linearmotor"
        private const val PRIVATE_EFFECT_BUILDER =
            "android.os.linearmotorvibrator.WaveformEffect\$Builder"
        private const val PRIVATE_EFFECT_CLASS =
            "android.os.linearmotorvibrator.WaveformEffect"
        private const val PRIVATE_EFFECT_TYPE = 302
        private const val PRIVATE_EFFECT_STRENGTH = 2
    }

    private var channel: MethodChannel? = null

    /**
     * Whether a turn should tick.
     *
     * Pushed down from the app's settings rather than read from them: the
     * platform has no business parsing the app's preferences, and the value has
     * to be known before the first turn rather than when the settings page is
     * first opened.
     */
    private var vibrateEnabled = true

    /**
     * Vibration runs off the main thread.
     *
     * The tick is owed on the same frame as the scroll it acknowledges, and a
     * binder round trip to the vibrator service on the UI thread is a visible
     * stutter in the list. The stock widget posts to its own HandlerThread for
     * the same reason.
     */
    private var vibratorThread: HandlerThread? = null
    private var vibratorHandler: Handler? = null

    /** The private linear-motor service, resolved once on first use. */
    private var linearMotor: Any? = null
    private var linearMotorChecked = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val created = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        created.setMethodCallHandler { call, result ->
            when (call.method) {
                /* The switch, pushed down from the app's settings. */
                "setVibrate" -> {
                    vibrateEnabled = call.arguments as? Boolean ?: true
                    result.success(null)
                }
                /* Asked for by the app once a turn has actually moved a list. */
                "tick" -> {
                    if (vibrateEnabled) {
                        tick()
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        channel = created
    }

    /**
     * The crown's events, taken at the first point the activity sees them.
     *
     * `onGenericMotionEvent` is not enough here: a Flutter activity hands motion
     * events to its own view, and an override at the `on…` level never runs —
     * the crown turned, the kernel logged it, and nothing in this class was
     * called. Dispatching is above that hand-off, so intercepting here is what
     * actually catches the turn.
     */
    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean {
        if (handleRotary(event)) {
            return true
        }
        return super.dispatchGenericMotionEvent(event)
    }

    /** Turns one motion event into scrolling plus a tick; false if it is not the crown's. */
    private fun handleRotary(event: MotionEvent): Boolean {
        if (event.action != MotionEvent.ACTION_SCROLL) {
            return false
        }

        /*
         * The turning axis is whichever one is not flat, tried in the order the
         * stock widget tries them: this watch carries the crown on AXIS_VSCROLL
         * and reports zero for the other two.
         *
         * There is deliberately no source test. Which source the platform names
         * for a crown is not portable — AOSP defines SOURCE_ROTARY_ENCODER,
         * this watch sends SOURCE_MOUSE (0x2002) — and two attempts at naming
         * the right one both guessed wrong, dropping every event before it was
         * read. What identifies a crown turn is the axis movement, not the
         * label: a scroll action with a moving scroll axis is a turn.
         */
        val position = when {
            event.getAxisValue(MotionEvent.AXIS_VSCROLL) != 0f ->
                event.getAxisValue(MotionEvent.AXIS_VSCROLL)
            event.getAxisValue(MotionEvent.AXIS_SCROLL) != 0f ->
                event.getAxisValue(MotionEvent.AXIS_SCROLL)
            event.getAxisValue(MotionEvent.AXIS_HSCROLL) != 0f ->
                event.getAxisValue(MotionEvent.AXIS_HSCROLL)
            else -> return false
        }

        /*
         * The axis already reports this event's movement, not a running
         * position: a turn drives it out to about -120 and it then decays back
         * through -4 to 0 as the movement settles. Differencing consecutive
         * values — what the previous version did — read that decay as a second
         * movement in the opposite direction, so the list jumped forward on the
         * turn and back again as it settled.
         */
        val delta = -position
        if (delta == 0f) {
            return true
        }

        /*
         * Only the movement is sent. Whether there is anything to move — and so
         * whether the turn deserves a tick — belongs to the app: it holds the
         * lists, and a page whose list already sits at its end has nowhere to
         * go. Ticking here answered every turn, including those, which is why a
         * page with nothing to scroll buzzed under the finger.
         */
        channel?.invokeMethod("scroll", delta.toDouble())
        return true
    }

    private fun tick() {
        val handler = handler()
        if (handler == null) {
            vibrate()
            return
        }
        handler.post { vibrate() }
    }

    private fun vibrate() {
        val context = applicationContext
        val motor = linearMotor(context)
        if (motor != null && vibrateWithPrivateEffect(motor)) {
            return
        }
        vibrateWithPublicEffect(context)
    }

    /**
     * The private service, or null when this build has no such service.
     *
     * Looked up through the same `getSystemService` name the stock widget uses.
     * A miss is cached: the lookup is a map hit, but there is no point repeating
     * it on every tick of a watch that will never have the answer.
     */
    private fun linearMotor(context: Context): Any? {
        if (linearMotorChecked) {
            return linearMotor
        }
        linearMotorChecked = true
        linearMotor = runCatching { context.getSystemService(PRIVATE_SERVICE) }.getOrNull()
        return linearMotor
    }

    /** Builds the stock WaveformEffect by reflection and fires it. */
    private fun vibrateWithPrivateEffect(motor: Any): Boolean = runCatching {
        val builderClass = Class.forName(PRIVATE_EFFECT_BUILDER)
        val builder = builderClass.getDeclaredConstructor().newInstance()

        builderClass.getMethod("setEffectType", Int::class.javaPrimitiveType)
            .invoke(builder, PRIVATE_EFFECT_TYPE)
        builderClass.getMethod("setEffectStrength", Int::class.javaPrimitiveType)
            .invoke(builder, PRIVATE_EFFECT_STRENGTH)
        builderClass.getMethod("setEffectLoop", Boolean::class.javaPrimitiveType)
            .invoke(builder, false)

        val effect = builderClass.getMethod("build").invoke(builder) ?: return false

        motor.javaClass
            .getMethod("vibrate", Class.forName(PRIVATE_EFFECT_CLASS))
            .invoke(motor, effect)
        true
    }.getOrDefault(false)

    /**
     * The public stand-in.
     *
     * `VibratorManager` arrived in API 31 and the deprecated service call is the
     * only route below it; the app's floor is 27, so both are kept rather than
     * buzzing nothing on an older watch.
     */
    private fun vibrateWithPublicEffect(context: Context) {
        val vibrator = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                context.getSystemService(VibratorManager::class.java)?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            }
        }.getOrNull() ?: return

        runCatching {
            vibrator.vibrate(
                VibrationEffect.createOneShot(FALLBACK_MS, FALLBACK_AMPLITUDE)
            )
        }
    }

    private fun handler(): Handler? {
        vibratorHandler?.let { return it }
        return runCatching {
            val thread = HandlerThread("crown_tick")
            thread.start()
            val created = Handler(thread.looper)
            vibratorThread = thread
            vibratorHandler = created
            created
        }.getOrNull()
    }

    override fun onDestroy() {
        vibratorHandler = null
        vibratorThread?.quitSafely()
        vibratorThread = null
        super.onDestroy()
    }
}
