import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;

//
// MonDraw.mc — Text that stays inside the round screen of the FR255.
//
// On a round screen a line too long for its height spills out of the circle.
// Here every line measures the chord of the screen at the height where it is
// drawn: if the text does not fit it switches to a smaller font, and if that is
// not enough it is shortened.
//
module MonDraw {

    const MARGIN = 8;          // px left free on both sides of the chord

    // From the smallest to the largest: the order in which fonts are scaled.
    function fonts() as Array {
        return [Graphics.FONT_XTINY, Graphics.FONT_TINY, Graphics.FONT_SMALL,
                Graphics.FONT_MEDIUM, Graphics.FONT_LARGE];
    }

    // Draws `s` centred, with its top at `yFrac` of the height, in the colour
    // already set on `dc`.
    function text(dc as Graphics.Dc, yFrac as Float, font, s as String) as Void {
        var y = dc.getHeight() * yFrac;
        var fs = fonts();
        var i = fs.indexOf(font);
        var f = font;
        var max = width(dc, y, dc.getFontHeight(f));
        while (dc.getTextWidthInPixels(s, f) > max && i > 0) {
            i--;
            f = fs[i];
            max = width(dc, y, dc.getFontHeight(f));
        }
        while (dc.getTextWidthInPixels(s, f) > max && s.length() > 3) {
            s = s.substring(0, s.length() - 3) + "..";
        }
        dc.drawText(dc.getWidth() / 2, y, f, s, Graphics.TEXT_JUSTIFY_CENTER);
    }

    // Usable width for a line `fh` high with its top at `y`: on a round screen
    // what counts is the edge of the line farthest from the centre.
    function width(dc as Graphics.Dc, y, fh as Number) as Number {
        var w = dc.getWidth();
        if (System.getDeviceSettings().screenShape != System.SCREEN_SHAPE_ROUND) {
            return w - 2 * MARGIN;
        }
        var r = w / 2.0;
        var c = dc.getHeight() / 2.0;
        var d = y - c;
        if (d < 0) { d = -d; }
        var d2 = y + fh - c;
        if (d2 < 0) { d2 = -d2; }
        if (d2 > d) { d = d2; }
        if (d >= r) { return 0; }
        return (2 * Math.sqrt(r * r - d * d)).toNumber() - 2 * MARGIN;
    }
}
