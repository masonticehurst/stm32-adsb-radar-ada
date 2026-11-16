--  Details panel for one tapped aircraft, drawn on the overlay layer:
--
--     +---------------------- [X]+
--     | LXJ590                   |   callsign, or ICAO if none yet
--     | ICAO   A79DFA            |
--     | BAND   1090 ES           |   or 978 UAT
--     | ALT    7,425 FT          |   GROUND / ---
--     | V/S    -1,088 FPM        |
--     | TRK    155               |
--     | GS     296 KT            |
--     | LAT    41.45654N         |
--     | LON    074.07419W        |
--     | DIST   3.9 NM            |   from own ship
--     | BRG    216               |
--     | SEEN   2 S AGO           |
--     | [   CENTER & FOLLOW    ] |   FOLLOWING (filled) while followed
--     +--------------------------+
--
--  It sits at the left of the screen, clear of the zoom/centre buttons.
--  Touches inside it never reach the map; [X] closes it. The bottom button
--  keeps the map centred on this aircraft (greyed out while it has no
--  current position); tapped again, it stops following.

with HAL.Bitmap;
with Interfaces; use Interfaces;

with Geo;

package Track_Popup is

   --  Draw the panel for this aircraft (nothing if it is not in the
   --  Traffic table). Following: the map is following this aircraft.
   procedure Draw
     (Buffer       : HAL.Bitmap.Any_Bitmap_Buffer; ICAO : Unsigned_32;
      Own_Position : Geo.Position; Following : Boolean);

   --  Screen point inside the panel
   function Contains (X, Y : Integer) return Boolean;

   --  Screen point on the close button (with a little extra touch area)
   function Close_Hit (X, Y : Integer) return Boolean;

   --  Screen point on the centre-and-follow button
   function Follow_Hit (X, Y : Integer) return Boolean;

end Track_Popup;
