package com.dailyduas.daily_duas

import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime

/**
 * Mirrors lib/domain/schedule.dart nextOccurrence: the smallest instant strictly after [after] that falls
 * on ISO [weekday] (Mon=1..Sun=7) at local [hour]:[minute] in after's zone. ZonedDateTime.of gives the
 * documented DST rules: a gap shifts the time later by the gap length, an overlap takes the earlier offset.
 */
object NextOccurrence {
    fun next(hour: Int, minute: Int, weekday: Int, after: ZonedDateTime): ZonedDateTime {
        val time = LocalTime.of(hour, minute)
        val start = after.toLocalDate()
        for (i in 0..14) {
            val day = start.plusDays(i.toLong())
            if (day.dayOfWeek.value != weekday) continue
            val candidate = ZonedDateTime.of(day, time, after.zone)
            if (candidate.isAfter(after)) return candidate
        }
        return ZonedDateTime.of(start.plusWeeks(1), time, after.zone) // unreachable for weekday in 1..7
    }

    fun nextMs(hour: Int, minute: Int, weekday: Int, afterMs: Long): Long {
        val after = ZonedDateTime.ofInstant(java.time.Instant.ofEpochMilli(afterMs), ZoneId.systemDefault())
        return next(hour, minute, weekday, after).toInstant().toEpochMilli()
    }
}
