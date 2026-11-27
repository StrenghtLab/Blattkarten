package de.blattkarten.android;

import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.widget.RemoteViews;
import java.text.SimpleDateFormat;
import java.util.Calendar;
import java.util.Locale;

public final class FlameWidget extends AppWidgetProvider {
    private static final String PREFS = "lernflamme";

    static void record(Context context, boolean practice) {
        SharedPreferences prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        Calendar today = Calendar.getInstance();
        SimpleDateFormat format = new SimpleDateFormat("yyyy-MM-dd", Locale.ROOT);
        String date = format.format(today.getTime());
        String last = prefs.getString("last", "");
        int count = prefs.getInt("streak", 0);
        today.add(Calendar.DATE, -1);
        if (!date.equals(last)) count = format.format(today.getTime()).equals(last) ? count + 1 : 1;
        prefs.edit().putString("last", date).putInt("streak", count)
                .putInt("record", Math.max(count, prefs.getInt("record", 0)))
                .putInt(practice ? "answers" : "imports", prefs.getInt(practice ? "answers" : "imports", 0) + 1)
                .apply();
        AppWidgetManager manager = AppWidgetManager.getInstance(context);
        update(context, manager, manager.getAppWidgetIds(new ComponentName(context, FlameWidget.class)));
    }

    static int streak(Context context) {
        SharedPreferences prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        SimpleDateFormat format = new SimpleDateFormat("yyyy-MM-dd", Locale.ROOT);
        Calendar day = Calendar.getInstance();
        String now = format.format(day.getTime());
        day.add(Calendar.DATE, -1);
        String last = prefs.getString("last", "");
        return last.equals(now) || last.equals(format.format(day.getTime())) ? prefs.getInt("streak", 0) : 0;
    }

    static SharedPreferences preferences(Context context) { return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE); }

    @Override public void onUpdate(Context context, AppWidgetManager manager, int[] ids) { update(context, manager, ids); }

    private static void update(Context context, AppWidgetManager manager, int[] ids) {
        for (int id : ids) {
            RemoteViews view = new RemoteViews(context.getPackageName(), R.layout.flame_widget);
            int days = streak(context);
            view.setTextViewText(R.id.flame_widget_streak, days + (days == 1 ? " Lerntag" : " Lerntage"));
            view.setOnClickPendingIntent(R.id.flame_widget, PendingIntent.getActivity(context, 0,
                    new Intent(context, MainActivity.class), PendingIntent.FLAG_IMMUTABLE));
            manager.updateAppWidget(id, view);
        }
    }
}
