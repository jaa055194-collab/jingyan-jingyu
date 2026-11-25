package com.jingyu.client_flutter

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaDataSource
import android.media.MediaPlayer
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicLong

/** Main-thread, foreground-only playback. No file, URI, or service is involved. */
internal class VoiceMessagePlayback(
    context: Context,
    private val event: (String, Map<String, Any>) -> Unit,
) {
    companion object {
        private const val MAX_BYTES = 8 * 1024 * 1024
        private const val PREPARE_LIMIT_MS = 10_000L
        private val epochs = AtomicLong()
    }

    private val handler = Handler(Looper.getMainLooper())
    private val audioManager = context.getSystemService(AudioManager::class.java)
    private val attributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()
    private var active: Playback? = null
    var epoch = epochs.incrementAndGet()
        private set
    var resumed = false
        private set

    fun setForeground(value: Boolean) {
        if (resumed == value) return
        resumed = value
        invalidate()
    }

    /** Invalidates delayed commands even if the Activity later resumes. */
    fun invalidate() {
        epoch = epochs.incrementAndGet()
        stop()
        event("voicePlaybackForeground", mapOf("epoch" to epoch, "resumed" to resumed))
    }

    fun play(id: Long, expectedEpoch: Long, bytes: ByteArray, reply: MethodChannel.Result) {
        if (!resumed || expectedEpoch != epoch || id < 1 ||
            bytes.isEmpty() || bytes.size > MAX_BYTES || active != null
        ) {
            reply.success(false)
            return
        }
        val playback = Playback(id, expectedEpoch, MediaPlayer(), MemoryAudio(bytes), reply)
        active = playback
        try {
            val player = playback.player
            player.setAudioAttributes(attributes)
            player.setOnPreparedListener { onPrepared(playback) }
            player.setOnCompletionListener { finish(playback, failed = false) }
            player.setOnErrorListener { _, _, _ ->
                finish(playback, failed = true)
                true
            }
            player.setDataSource(playback.source)
            playback.timeout = Runnable { finish(playback, failed = true) }
            handler.postDelayed(playback.timeout!!, PREPARE_LIMIT_MS)
            player.prepareAsync()
        } catch (_: Exception) {
            finish(playback, failed = true)
        }
    }

    private fun onPrepared(playback: Playback) {
        if (active !== playback || !resumed || playback.epoch != epoch) return
        playback.timeout?.let(handler::removeCallbacks)
        playback.timeout = null
        try {
            val focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(attributes)
                .setWillPauseWhenDucked(true)
                .setOnAudioFocusChangeListener({ change ->
                    // Do not resume playback on focus gain.
                    if (change < 0) finish(playback, failed = false)
                }, handler)
                .build()
            if (audioManager?.requestAudioFocus(focus) != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                finish(playback, failed = true)
                return
            }
            playback.focus = focus
            playback.player.start()
            playback.reply?.success(true)
            playback.reply = null
        } catch (_: Exception) {
            finish(playback, failed = true)
        }
    }

    fun stop(id: Long? = null) {
        val playback = active ?: return
        if (id == null || id == playback.id) release(playback)
    }

    private fun finish(playback: Playback, failed: Boolean) {
        if (active !== playback) return
        val started = playback.reply == null
        release(playback)
        if (started) {
            event("voicePlaybackFinished", mapOf("requestId" to playback.id, "failed" to failed))
        }
    }

    private fun release(playback: Playback) {
        // Clear identity first: a queued callback from this player is stale.
        active = null
        playback.timeout?.let(handler::removeCallbacks)
        try {
            playback.player.release()
        } finally {
            playback.source.close()
            playback.focus?.let { audioManager?.abandonAudioFocusRequest(it) }
            playback.reply?.success(false)
            playback.reply = null
        }
    }

    private class Playback(
        val id: Long,
        val epoch: Long,
        val player: MediaPlayer,
        val source: MemoryAudio,
        var reply: MethodChannel.Result?,
    ) {
        var timeout: Runnable? = null
        var focus: AudioFocusRequest? = null
    }

    private class MemoryAudio(private var bytes: ByteArray?) : MediaDataSource() {
        @Synchronized
        override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
            val source = bytes ?: return -1
            if (size == 0) return 0
            if (position < 0 || position >= source.size ||
                offset < 0 || size < 0 || offset > buffer.size - size
            ) return -1
            val start = position.toInt()
            val count = minOf(size, source.size - start)
            source.copyInto(buffer, offset, start, start + count)
            return count
        }

        @Synchronized
        override fun getSize(): Long = bytes?.size?.toLong() ?: 0L

        @Synchronized
        override fun close() {
            bytes = null
        }
    }
}
