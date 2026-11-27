package de.blattkarten.android;

import android.graphics.Canvas;
import android.graphics.ColorFilter;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PixelFormat;
import android.graphics.drawable.Drawable;

final class StudioIcon extends Drawable {
    private final Paint pen = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final String name;
    private final int tint;

    StudioIcon(String name, int tint) {
        this.name = name;
        this.tint = tint;
        pen.setStrokeCap(Paint.Cap.ROUND);
        pen.setStrokeJoin(Paint.Join.ROUND);
        pen.setStrokeWidth(1.65f);
        pen.setStyle(Paint.Style.STROKE);
    }

    @Override public void draw(Canvas canvas) {
        canvas.save();
        canvas.translate(getBounds().left, getBounds().top);
        canvas.scale(getBounds().width() / 24f, getBounds().height() / 24f);
        pen.setColor(tint);
        switch (name) {
            case "Start":
                line(canvas, 3,11,12,4,21,11);
                line(canvas, 5,10,5,20,10,20,10,15,14,15,14,20,19,20,19,10);
                break;
            case "Sammlung":
                canvas.drawRoundRect(5, 6, 20, 19, 2, 2, pen);
                line(canvas, 3,16,3,5,5,3,17,3);
                line(canvas, 9,11,16,11);
                break;
            case "KI-Studio":
            case "Chat":
                line(canvas, 11,3,13,9,19,11,13,13,11,19,9,13,3,11,9,9,11,3);
                line(canvas, 19,3,19,7);
                line(canvas, 17,5,21,5);
                break;
            case "Üben":
            case "Physik":
                line(canvas, 12,3,5,13,11,13,10,21,19,10,13,10,12,3);
                break;
            case "Zeit":
                canvas.drawCircle(12,12,8.5f,pen);
                line(canvas, 12,7,12,12,16,14);
                break;
            case "Flamme":
                Path flame = new Path();
                flame.moveTo(12,3);
                flame.cubicTo(14,8,20,9,19,15);
                flame.cubicTo(19,23,5,23,5,15);
                flame.cubicTo(5,11,8,10,8,7);
                flame.quadTo(10,9,10,11);
                flame.quadTo(13,7,12,3);
                canvas.drawPath(flame,pen);
                break;
            case "Kamera":
                line(canvas, 4,7,8,7,10,5,14,5,16,7,20,7,20,19,4,19,4,7);
                canvas.drawCircle(12,12.5f,3,pen);
                break;
            case "Mathematik":
                line(canvas, 5,8,11,8); line(canvas, 8,5,8,11);
                line(canvas, 14,8,20,8); line(canvas, 6,14,10,18); line(canvas, 6,18,10,14);
                line(canvas, 14,15,20,15); line(canvas, 14,18,20,18);
                break;
            case "Chemie":
                line(canvas, 9,4,15,4); line(canvas, 10,4,10,10,5,18,6,20,18,20,19,18,14,10,14,4);
                line(canvas, 8,15,16,15);
                break;
            case "Biologie":
                Path leaf = new Path();
                leaf.moveTo(5,19); leaf.quadTo(3,7,19,5); leaf.quadTo(20,19,5,19);
                canvas.drawPath(leaf,pen); line(canvas, 5,19,14,10);
                break;
            case "Erdkunde":
            case "Englisch":
                canvas.drawCircle(12,12,8.5f,pen);
                canvas.drawOval(8,3.5f,16,20.5f,pen);
                line(canvas, 4,12,20,12);
                break;
            case "Geschichte":
                line(canvas, 4,8,12,4,20,8,4,8);
                line(canvas, 4,20,20,20); line(canvas, 7,9,7,18);
                line(canvas, 12,9,12,18); line(canvas, 17,9,17,18);
                break;
            case "Deutsch":
                line(canvas, 12,7,9,5,4,5,4,18,9,18,12,20,15,18,20,18,20,5,15,5,12,7,12,20);
                break;
            case "Pfeil":
                line(canvas, 10,6,15,12,10,18);
                break;
            default:
                line(canvas, 4,7,10,7,12,9,20,9,20,19,4,19,4,7);
                break;
        }
        canvas.restore();
    }

    private void line(Canvas canvas, float... points) {
        Path shape = new Path();
        shape.moveTo(points[0], points[1]);
        for (int i = 2; i < points.length; i += 2) shape.lineTo(points[i], points[i+1]);
        canvas.drawPath(shape, pen);
    }

    @Override public void setAlpha(int alpha) { pen.setAlpha(alpha); }
    @Override public void setColorFilter(ColorFilter filter) { pen.setColorFilter(filter); }
    @Override public int getOpacity() { return PixelFormat.TRANSLUCENT; }
}
