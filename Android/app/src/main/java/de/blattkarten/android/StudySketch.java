package de.blattkarten.android;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.view.View;
import java.util.Locale;

final class StudySketch extends View {
    private final int kind;
    private final Paint pen = new Paint(Paint.ANTI_ALIAS_FLAG);
    private static final int VIOLET = Color.rgb(93, 58, 169);
    private static final int TEAL = Color.rgb(21, 110, 87);
    private static final int CORAL = Color.rgb(183, 57, 78);

    static StudySketch forCard(Context context, String text) {
        String t = text.toLowerCase(Locale.GERMAN);
        int kind = t.contains("stromkreis") || t.contains("reihenschaltung") ? 1
                : t.contains("zellkern") || t.contains("zellmembran") || t.contains("mitochondri") ? 2
                : t.contains("parabel") ? 3 : t.contains("wassermolekül") ? 4
                : t.contains("geschwindigkeit") || t.contains("beschleunigung") ? 5 : 0;
        return kind == 0 ? null : new StudySketch(context, kind);
    }

    private StudySketch(Context context, int kind) {
        super(context);
        this.kind = kind;
        setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
    }

    @Override protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        float scale = Math.min(getWidth() / 280f, getHeight() / 80f);
        canvas.save();
        canvas.translate((getWidth() - 280 * scale) / 2, (getHeight() - 80 * scale) / 2);
        canvas.scale(scale, scale);
        pen.setStyle(Paint.Style.STROKE);
        pen.setStrokeWidth(2.7f);
        pen.setStrokeCap(Paint.Cap.ROUND);
        pen.setColor(TEAL);
        if (kind == 1) {
            canvas.drawRect(65, 13, 215, 66, pen);
            pen.setColor(Color.WHITE);
            pen.setStyle(Paint.Style.FILL);
            canvas.drawRect(111, 5, 167, 23, pen);
            pen.setColor(VIOLET);
            pen.setStyle(Paint.Style.STROKE);
            canvas.drawRoundRect(112, 5, 166, 23, 3, 3, pen);
            pen.setColor(TEAL);
            canvas.drawLine(52, 42, 78, 42, pen);
            canvas.drawLine(57, 49, 73, 49, pen);
        } else if (kind == 2) {
            canvas.drawOval(81, 9, 199, 72, pen);
            pen.setColor(VIOLET);
            canvas.drawOval(115, 22, 158, 59, pen);
            canvas.drawLine(151, 26, 185, 13, pen);
            caption(canvas, "Kern", 190, 17, VIOLET);
        } else if (kind == 3) {
            canvas.drawLine(63, 62, 219, 62, pen);
            canvas.drawLine(140, 8, 140, 72, pen);
            Path curve = new Path();
            curve.moveTo(95, 10);
            curve.quadTo(140, 115, 185, 10);
            pen.setColor(VIOLET);
            canvas.drawPath(curve, pen);
            caption(canvas, "x", 226, 65, TEAL);
            caption(canvas, "y", 146, 14, TEAL);
        } else if (kind == 4) {
            canvas.drawLine(121, 48, 132, 35, pen);
            canvas.drawLine(148, 35, 159, 48, pen);
            pen.setColor(CORAL);
            canvas.drawCircle(140, 24, 16, pen);
            pen.setColor(VIOLET);
            canvas.drawCircle(110, 56, 13, pen);
            canvas.drawCircle(170, 56, 13, pen);
            caption(canvas, "O", 136, 28, CORAL);
            caption(canvas, "H", 106, 60, VIOLET);
            caption(canvas, "H", 166, 60, VIOLET);
        } else {
            arrow(canvas, 82, 57, 145);
            arrow(canvas, 82, 24, 191);
            caption(canvas, "v₁", 153, 61, TEAL);
            caption(canvas, "v₂", 200, 28, TEAL);
        }
        canvas.restore();
    }

    private void arrow(Canvas canvas, float x, float y, float end) {
        canvas.drawLine(x, y, end, y, pen);
        canvas.drawLine(end - 10, y - 7, end, y, pen);
        canvas.drawLine(end - 10, y + 7, end, y, pen);
    }

    private void caption(Canvas canvas, String text, float x, float y, int color) {
        pen.setStyle(Paint.Style.FILL);
        pen.setColor(color);
        pen.setTextSize(12);
        canvas.drawText(text, x, y, pen);
        pen.setStyle(Paint.Style.STROKE);
    }
}
