{-# LANGUAGE NoMonomorphismRestriction #-}

import Diagrams.Prelude
import Diagrams.Backend.PGF.CmdLine
import Diagrams.TwoD.Vector         (perp)

type D2 = Diagram PGF V2 Double

main = onlineMain example

mytext :: OnlineTeX D2
mytext = scale 2 . box 8 orange <$> onlineHbox (sizedVBox 18 txt)
  where
    txt = "The sum of the squares of the lengths of the legs equals the square "
       ++ "of the length of the hypotenuse."
       ++ "$$ a^2 + b^2 = c^2 .$$"

rightTriangle
  = fromVertices [origin, 4 ^& 0, 4 ^& 3]
      # closeTrail
      # strokeTrail
      # centerXY
      # scale 12
      # fc dodgerblue

labeledTriangle = scale 5 <$> do
  a <- onlineHbox "$a$"
  b <- onlineHbox "$b$"
  c <- onlineHbox "$c$"

  return $ rightTriangle
             # labeled a unit_X
             # labeled b unit_Y
             # labeled c (V2 4 3)

example = frame 10 <$> liftA2 (|-|) labeledTriangle mytext
  where
    a |-| b = a ||| strutX 25 ||| b

--

box padding colour content
  = centerXY content
 <> roundedRect w h 2
      # fc colour
  where V2 w h = (+padding) <$> size content

sizedVBox w x = "\\hsize=" ++ show w ++ "em\\vbox{\\noindent " ++ x ++ "}"

labeled l v a = besideWithGap 3 (perp v) a (centerXY l)

-- is there a better way to do this?
besideWithGap g v a b = beside v a b'
  where
    b' = beside v (strut (g *^ signorm v)) b

