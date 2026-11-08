package odnetlib

import "core:time"
import "core:sync"

Date_Cache :: struct {
	buffer:     [30]u8,
	date_str:   string,
	last_sec:   i64,
	mutex:      sync.Mutex,
}

DAYS := [7]string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
MONTHS := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}

global_date_cache: Date_Cache

format_two_digits :: #force_inline proc(buf: []u8, offset: int, val: int) {
	buf[offset]     = u8('0' + (val / 10) % 10)
	buf[offset + 1] = u8('0' + val % 10)
}

format_four_digits :: #force_inline proc(buf: []u8, offset: int, val: int) {
	buf[offset]     = u8('0' + (val / 1000) % 10)
	buf[offset + 1] = u8('0' + (val / 100) % 10)
	buf[offset + 2] = u8('0' + (val / 10) % 10)
	buf[offset + 3] = u8('0' + val % 10)
}

format_http_date_time :: proc(t: time.Time, buf: []u8) -> string {
	if len(buf) < 29 do return ""

	y, m, d := time.date(t)
	w := time.weekday(t)
	h, min, s := time.clock(t)

	day_str := DAYS[int(w)]
	buf[0] = day_str[0]
	buf[1] = day_str[1]
	buf[2] = day_str[2]
	buf[3] = ','
	buf[4] = ' '

	format_two_digits(buf, 5, d)
	buf[7] = ' '

	month_str := MONTHS[int(m) - 1]
	buf[8]  = month_str[0]
	buf[9]  = month_str[1]
	buf[10] = month_str[2]
	buf[11] = ' '

	format_four_digits(buf, 12, y)
	buf[16] = ' '

	format_two_digits(buf, 17, h)
	buf[19] = ':'
	format_two_digits(buf, 20, min)
	buf[22] = ':'
	format_two_digits(buf, 23, s)
	buf[25] = ' '

	buf[26] = 'G'
	buf[27] = 'M'
	buf[28] = 'T'

	return string(buf[:29])
}

update_date_cache :: proc() -> string {
	now := time.now()
	sec := time.to_unix_nanoseconds(now) / 1e9

	if sec == global_date_cache.last_sec && len(global_date_cache.date_str) > 0 {
		return global_date_cache.date_str
	}

	sync.lock(&global_date_cache.mutex)
	defer sync.unlock(&global_date_cache.mutex)

	if sec == global_date_cache.last_sec && len(global_date_cache.date_str) > 0 {
		return global_date_cache.date_str
	}

	global_date_cache.last_sec = sec
	global_date_cache.date_str = format_http_date_time(now, global_date_cache.buffer[:])
	return global_date_cache.date_str
}
