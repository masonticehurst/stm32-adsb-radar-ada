--  Small number-to-text helpers for the screen (no heap, no Text_IO)

with Interfaces; use Interfaces;

package Text_Format is

   --  'Image without the leading space: 42 -> "42", -7 -> "-7"
   function Img (N : Integer) return String;

   --  With thousands separators: 21325 -> "21,325", -1600 -> "-1,600"
   function Grouped (N : Integer) return String;

   --  24-bit ICAO address as 6 hex digits: "A779BB"
   function Hex6 (Value : Unsigned_32) return String;

   --  32-bit register value as 8 hex digits: "7EEF97FF"
   function Hex8 (Value : Unsigned_32) return String;

   --  Five decimals and a hemisphere letter, whole part zero-padded to
   --  Int_Width: (41.5096, 'N', 'S', 2) -> "41.50960N",
   --  (-74.0232, 'E', 'W', 3) -> "074.02320W"
   function Degrees
     (Value     : Long_Float; Positive : Character; Negative : Character;
      Int_Width : Natural) return String;

   --  One decimal place, rounded: 3.86 -> "3.9"
   function Tenths (Value : Long_Float) return String;

end Text_Format;
