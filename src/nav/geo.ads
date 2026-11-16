--  Geographic maths for the Web Mercator (XYZ) map.
--
--  "World pixels" are pixel coordinates on the whole Web Mercator map at a
--  given zoom: 256 * 2**Zoom pixels square, X growing east from 180 W and
--  Y growing south from 85.05 N. Tile (X, Y) covers world pixels
--  X*256 .. X*256+255 and Y*256 .. Y*256+255.

package Geo is

   Max_Mercator_Lat : constant := 85.051_128_78;

   subtype Latitude is Long_Float range -90.0 .. 90.0;
   subtype Longitude is Long_Float range -180.0 .. 180.0;

   type Position is record
      Lat : Latitude;   --  degrees, north positive
      Lon : Longitude;  --  degrees, east positive
   end record;

   subtype Zoom_Level is Natural range 0 .. 22;

   type World_Pixel is record
      X, Y : Long_Float;
   end record;

   --  Latitudes beyond +/-85.05 degrees are clamped to the map edge
   function To_World_Pixel
     (P : Position; Zoom : Zoom_Level) return World_Pixel;

   --  Inverse of To_World_Pixel. Pixels off the world are clamped to its
   --  edge.
   function From_World_Pixel
     (P : World_Pixel; Zoom : Zoom_Level) return Position;

   --  Screen pixels per nautical mile at this latitude and zoom, for
   --  drawing range rings: 1852 * 2**Zoom / (156543.03 * cos (Lat))
   function Pixels_Per_NM
     (Lat : Latitude; Zoom : Zoom_Level) return Long_Float;

   --  Great-circle distance in nautical miles (haversine, spherical Earth)
   function Distance_NM (From, To : Position) return Long_Float;

   --  Initial true bearing from From to To, 0 .. 360 degrees (0 = north)
   function Bearing_Deg (From, To : Position) return Long_Float;

end Geo;
