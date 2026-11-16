--  Everything drawn over the map on the overlay layer: range rings and
--  own-ship symbol (centred on own ship, wherever it is on screen), range
--  and position text, map status, the touch buttons, ADS-B traffic from
--  the Traffic table (chevron along track + callsign/altitude label), and
--  the details panel of the selected aircraft (Track_Popup).

with Interfaces; use Interfaces;

with Geo;
with Map_View;

package Overlay is

   --  Redraw the whole overlay layer. View_Centre is the position in the
   --  middle of the screen; Following is False after the user panned away
   --  from own ship. Selected is the ICAO address of the aircraft whose
   --  details are shown, Followed the one the map is following; either
   --  can be Traffic.No_Aircraft. Notice, if not empty, is a short message
   --  shown in a box near the bottom, on top of everything (e.g.
   --  "SAVED SHOT0001.BMP"); Notice_Error draws it in red.
   procedure Draw
     (Own_Position : Geo.Position; View_Centre : Geo.Position;
      Zoom : Map_View.Map_Zoom; Following : Boolean; Selected : Unsigned_32;
      Followed     : Unsigned_32; Notice : String := "";
      Notice_Error : Boolean := False);

   --  ICAO address of the drawn aircraft nearest screen point (X, Y),
   --  within a finger's width, or Traffic.No_Aircraft
   function Pick_Aircraft
     (X, Y : Integer; View_Centre : Geo.Position; Zoom : Map_View.Map_Zoom)
      return Unsigned_32;

   --  Start-up screen: title and Message
   procedure Draw_Splash (Message : String);

end Overlay;
