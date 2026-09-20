package schedule

import (
	"reflect"
	"testing"
)

// Every list shape renders to an expression the validator accepts and
// Describe reads back as the same form — the round trip the UI relies on
// to show a saved expression as words.
func TestFormRoundTrip(t *testing.T) {
	cases := []struct {
		form Form
		expr string
	}{
		{Form{Kind: FormDaily, Hour: 3}, "0 3 * * *"},
		{Form{Kind: FormDaily, Hour: 23, Minute: 30}, "30 23 * * *"},
		{Form{Kind: FormWeekly, Weekday: 0, Hour: 3}, "0 3 * * 0"},
		{Form{Kind: FormWeekly, Weekday: 6, Hour: 22, Minute: 15}, "15 22 * * 6"},
		{Form{Kind: FormMonthly, Day: 1, Hour: 4}, "0 4 1 * *"},
		{Form{Kind: FormHourly}, "0 * * * *"},
		{Form{Kind: FormHourly, Minute: 30}, "30 * * * *"},
		{Form{Kind: FormMinutes, Every: 5}, "*/5 * * * *"},
		{Form{Kind: FormMinutes, Every: 30}, "*/30 * * * *"},
	}
	for _, c := range cases {
		got, err := c.form.Expression()
		if err != nil || got != c.expr {
			t.Errorf("%+v → %q, %v; want %q", c.form, got, err, c.expr)
			continue
		}
		if errs, ok := Validate(got); !ok {
			t.Errorf("%q does not validate: %v", got, errs)
		}
		if back := Describe(got); !reflect.DeepEqual(back, c.form) {
			t.Errorf("Describe(%q) = %+v, want %+v", got, back, c.form)
		}
	}
}

// What the form cannot say stays an expression: the UI must never show
// "daily at 03:00" for something that fires on two days or every second hour.
func TestDescribeKeepsForeignExpressions(t *testing.T) {
	foreign := []string{
		"0 3 * * 1,5", // two weekdays
		"0 3 * * mon", // a name (valid cron, but not a list shape)
		"0 */2 * * *", // every second hour
		"0 3 1-5 * *", // a day range
		"0 3 * 6 *",   // one month only
		"0 3 29 * *",  // the 29th: not every month has it
		"*/7 * * * *", // 7 does not divide 60
		"0 3 * * 8",   // weekday out of range
		"0 3 * *",     // four fields
		"@daily",      // shortcut
		"0 3 * * 1 extra",
	}
	for _, e := range foreign {
		if got := Describe(e); got.Kind != FormCron || got.Expr != e {
			t.Errorf("Describe(%q) = %+v, want cron with the expression kept", e, got)
		}
	}
	// Sunday written as 7 is still weekly, Sunday
	if got := Describe("0 3 * * 7"); got.Kind != FormWeekly || got.Weekday != 0 {
		t.Errorf("Describe(0 3 * * 7) = %+v", got)
	}
}

func TestFormRejectsOutOfRange(t *testing.T) {
	bad := []Form{
		{Kind: FormDaily, Hour: 24},
		{Kind: FormDaily, Minute: 60},
		{Kind: FormWeekly, Weekday: 7},
		{Kind: FormMonthly, Day: 0},
		{Kind: FormMonthly, Day: 31},
		{Kind: FormMinutes, Every: 7},
		{Kind: FormMinutes, Every: 0},
		{Kind: "yearly"},
	}
	for _, f := range bad {
		if expr, err := f.Expression(); err == nil {
			t.Errorf("%+v rendered %q, want an error", f, expr)
		}
	}
	if expr, err := (Form{Kind: FormCron, Expr: " 0 3 * * 1 "}).Expression(); err != nil || expr != "0 3 * * 1" {
		t.Errorf("cron passthrough = %q, %v", expr, err)
	}
}
