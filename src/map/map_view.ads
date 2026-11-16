--  Moving-map renderer: draws the pre-rendered tiles from the SD card
--  (Z08.BIN .. Z12.BIN, see Map_Tiles) onto the map layer, centred on a
--  position. Tiles are drawn 1:1, never scaled. Missing tiles, a missing
--  file or a missing card leave plain background.

with Geo;

package Map_View is

   subtype Map_Zoom is Geo.Zoom_Level range 8 .. 12;

   --  Display range, centre to top/bottom edge: 32 NM at zoom 8 down to
   --  2 NM at zoom 12
   function Range_NM (Zoom : Map_Zoom) return Positive is (2**(13 - Zoom));

   type Map_Status is
     (Not_Started, No_Card, Card_Error, No_Filesystem, Mounted);

   --  The card is mounted here, so its files are "/sdcard/NAME"
   Mount_Point : constant String := "sdcard";

   --  Reserve the tile cache, start the SD card, mount it and read every
   --  zoom file's header. Call after Screen.Initialize. Never raises.
   procedure Initialize;

   function Status return Map_Status;

   --  True when this zoom's file was found and its header is valid
   function Zoom_Available (Zoom : Map_Zoom) return Boolean;

   --  Short message for the screen, or "" when the map is fine
   function Status_Text (Zoom : Map_Zoom) return String;

   --  Centre moved, if needed, so that it lies inside this zoom's tile
   --  grid; stops the user panning off the map. Unchanged when the zoom's
   --  file is not available.
   function Clamp_To_Coverage
     (Centre : Geo.Position; Zoom : Map_Zoom) return Geo.Position;

   --  Redraw the whole map layer with Centre in the middle of the screen.
   --  Recently used tiles are kept in an SDRAM cache, so redraws while
   --  panning only read the tiles that come into view. Never raises.
   procedure Draw (Centre : Geo.Position; Zoom : Map_Zoom);

end Map_View;
