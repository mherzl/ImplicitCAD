-- Implicit CAD. Copyright (C) 2011, Christopher Olah (chris@colah.ca)
-- Copyright 2016, Julia Longtin (julial@turinglace.com)
-- Released under the GNU AGPLV3+, see LICENSE

-- Allow us to use explicit foralls when writing function type declarations.
{-# LANGUAGE ExplicitForAll #-}

-- Allow us to use the tearser parallel list comprehension syntax, to avoid having to call zip in the complicated comprehensions below.
{-# LANGUAGE ParallelListComp #-}

-- export getContour and getMesh, which returns the edge of a 2D object, or the surface of a 3D object, respectively.
module Graphics.Implicit.Export.Render (getMesh, getContour) where

import Prelude(ceiling, ($), (+), (*), max, div, tail, map, concat, reverse, (.), concatMap, min, Int)

import Graphics.Implicit.Definitions (ℝ, ℕ, Fastℕ, ℝ2, ℝ3, TriangleMesh, Obj2, Obj3, Polyline(Polyline), (⋯/), both, allthree, fromℕtoℝ, fromℕ)

import Data.VectorSpace ((^-^))

-- Here's the plan for rendering a cube (the 2D case is trivial):

-- (1) We calculate midpoints using interpolate.
--     This guarentees that our mesh will line up everywhere.
--     (Contrast with calculating them in getSegs)
import Graphics.Implicit.Export.Render.Interpolate (interpolate)

-- (2) We calculate the segments separating the inside and outside of our
--     object on the sides of the cube.
--     getSegs internally uses refine from RefineSegs to subdivide the segs
--     to better match the boundary.
import Graphics.Implicit.Export.Render.GetSegs (getSegs)

-- (3) We put the segments from all sides of the cube together
--     and extract closed loops.
import Graphics.Implicit.Export.Render.GetLoops (getLoops)

-- (4) We tesselate the loops, using a mixture of triangles and squares
import Graphics.Implicit.Export.Render.TesselateLoops (tesselateLoop)

-- (5) We try to merge squares, then turn everything into triangles.
import Graphics.Implicit.Export.Render.HandleSquares (mergedSquareTris)

-- Success: This is our mesh.

-- Each step on the Z axis is done in parallel using Control.Parallel.Strategies
import Control.Parallel.Strategies (using, rdeepseq, parBuffer)

import Control.DeepSeq (NFData)

-- The actual code is just a bunch of ugly argument passing.
-- Utility functions can be found at the end.

-- For efficiency, we need to avoid looking things up in other lists
-- (since they're 3D, it's an O(n³) operation...). So we need to make
-- our algorithms "flow" along the data structure instead of accessing
-- within it. To do this we use the ParallelListComp GHC extention.

-- We also compute lots of things in advance and pass them in as arguments,
-- to reduce redundant computations.

-- All in all, this is kind of ugly. But it is necessary.

-- Note: As far as the actual results of the rendering algorithm, nothing in
--       this file really matters. All the actual decisions about how to build
--       the mesh are abstracted into the imported files.

-- For the 2D case, we need one last thing, cleanLoopsFromSegs:
import Graphics.Implicit.Export.Render.HandlePolylines (cleanLoopsFromSegs)

-- Set the default types for the numbers in this file.
default (ℕ, Fastℕ, ℝ)

getMesh :: ℝ3 -> ℝ3 -> ℝ3 -> Obj3 -> TriangleMesh
getMesh p1@(x1,y1,z1) p2 res@(xres,yres,zres) obj =
    let
        -- How much space are we rendering?
        d = p2 ^-^ p1

        -- How many steps will we take on each axis?
        nx :: ℕ
        ny :: ℕ
        nz :: ℕ
        (nx,ny,nz) = ceiling `allthree` ( d ⋯/ res)

        -- How big are the steps?
        (rx,ry,rz) = d ⋯/ (fromℕtoℝ `allthree` (nx,ny,nz))

        -- The positions we're rendering.
        pXs = [ x1 + rx*(fromℕtoℝ n) | n <- [0.. nx] ]
        pYs = [ y1 + ry*(fromℕtoℝ n) | n <- [0.. ny] ]
        pZs = [ z1 + rz*(fromℕtoℝ n) | n <- [0.. nz] ]

        -- | performance tuning.
        -- FIXME: magic number.
        forcesteps :: Int
        forcesteps=32

        -- | Perform a given function on every point in a 3D grid.
        par3DList :: forall t. NFData t => ℕ -> ℕ -> ℕ -> ((ℕ -> ℝ) -> ℕ -> (ℕ -> ℝ) -> ℕ -> (ℕ -> ℝ) -> ℕ -> t) -> [[[t]]]
        par3DList lenx leny lenz f =
            [[[f
                (\n -> x1 + rx*fromℕtoℝ (mx+n)) mx
                (\n -> y1 + ry*fromℕtoℝ (my+n)) my
                (\n -> z1 + rz*fromℕtoℝ (mz+n)) mz
            | mx <- [0..lenx] ] | my <- [0..leny] ] | mz <- [0..lenz] ]
                `using` parBuffer (max 1 $ div (fromℕ $ lenx+leny+lenz) forcesteps) rdeepseq

        -- | Evaluate obj to avoid waste in mids, segs, later.
        objV = par3DList (nx+2) (ny+2) (nz+2) $ \x _ y _ z _ -> obj (x 0, y 0, z 0)

        -- (1) Calculate mid points on X, Y, and Z axis in 3D space.
        midsZ = [[[
                 interpolate (z0, objX0Y0Z0) (z1', objX0Y0Z1) (appABC obj x0 y0) zres
                 | x0 <- pXs |                   objX0Y0Z0 <- objY0Z0 | objX0Y0Z1 <- objY0Z1
                ]| y0 <- pYs |                   objY0Z0   <- objZ0   | objY0Z1   <- objZ1
                ]| z0 <- pZs | z1' <- tail pZs | objZ0     <- objV    | objZ1     <- tail objV
                ] `using` parBuffer (max 1 $ div (fromℕ nz) forcesteps) rdeepseq

        midsY = [[[
                 interpolate (y0, objX0Y0Z0) (y1', objX0Y1Z0) (appACB obj x0 z0) yres
                 | x0 <- pXs |                   objX0Y0Z0 <- objY0Z0 | objX0Y1Z0 <- objY1Z0
                ]| y0 <- pYs | y1' <- tail pYs | objY0Z0   <- objZ0   | objY1Z0   <- tail objZ0
                ]| z0 <- pZs |                   objZ0     <- objV
                ] `using` parBuffer (max 1 $ div (fromℕ ny) forcesteps) rdeepseq

        midsX = [[[
                 interpolate (x0, objX0Y0Z0) (x1', objX1Y0Z0) (appBCA obj y0 z0) xres
                 | x0 <- pXs | x1' <- tail pXs | objX0Y0Z0 <- objY0Z0 | objX1Y0Z0 <- tail objY0Z0
                ]| y0 <- pYs |                   objY0Z0   <- objZ0
                ]| z0 <- pZs |                   objZ0     <- objV
                ] `using` parBuffer (max 1 $ div (fromℕ nx) forcesteps) rdeepseq

        -- (2) Calculate segments for each side
        segsZ = [[[
            map (injZ z0) $ getSegs (x0,y0) (x1',y1') (obj **$ z0) (objX0Y0Z0, objX1Y0Z0, objX0Y1Z0, objX1Y1Z0) (midA0, midA1, midB0, midB1)
             | x0<-pXs | x1'<-tail pXs |midB0<-mX''  | midB1<-mX'T     | midA0<-mY''  | midA1<-tail mY''  | objX0Y0Z0<-objY0Z0 | objX1Y0Z0<- tail objY0Z0 | objX0Y1Z0<-objY1Z0    | objX1Y1Z0<-tail objY1Z0
            ]| y0<-pYs | y1'<-tail pYs |mX'' <-mX'   | mX'T <-tail mX' | mY'' <-mY'                       | objY0Z0  <-objZ0                              | objY1Z0  <-tail objZ0
            ]| z0<-pZs                 |mX'  <-midsX |                   mY'  <-midsY                     | objZ0    <-objV
            ] `using` parBuffer (max 1 $ div (fromℕ nz) forcesteps) rdeepseq

        segsY = [[[
            map (injY y0) $ getSegs (x0,z0) (x1',z1') (obj *$* y0) (objX0Y0Z0, objX1Y0Z0, objX0Y0Z1, objX1Y0Z1) (midA0, midA1, midB0, midB1)
             | x0<-pXs | x1'<-tail pXs | midB0<-mB''  | midB1<-mBT'       | midA0<-mA''  | midA1<-tail mA'' | objX0Y0Z0<-objY0Z0 | objX1Y0Z0<-tail objY0Z0 | objX0Y0Z1<-objY0Z1 | objX1Y0Z1<-tail objY0Z1
            ]| y0<-pYs |                 mB'' <-mB'   | mBT' <-mBT        | mA'' <-mA'                      | objY0Z0  <-objZ0                             | objY0Z1  <-objZ1
            ]| z0<-pZs | z1'<-tail pZs | mB'  <-midsX | mBT  <-tail midsX | mA'  <-midsZ                    | objZ0    <-objV                              | objZ1    <-tail objV
            ] `using` parBuffer (max 1 $ div (fromℕ ny) forcesteps) rdeepseq

        segsX = [[[
            map (injX x0) $ getSegs (y0,z0) (y1',z1') (obj $** x0) (objX0Y0Z0, objX0Y1Z0, objX0Y0Z1, objX0Y1Z1) (midA0, midA1, midB0, midB1)
             | x0<-pXs |                 midB0<-mB''  | midB1<-mBT'       | midA0<-mA''  | midA1<-mA'T     | objX0Y0Z0<-objY0Z0 | objX0Y1Z0<-objY1Z0    | objX0Y0Z1<-objY0Z1    | objX0Y1Z1<-     objY1Z1
            ]| y0<-pYs | y1'<-tail pYs | mB'' <-mB'   | mBT' <-mBT        | mA'' <-mA'   | mA'T <-tail mA' | objY0Z0  <-objZ0   | objY1Z0  <-tail objZ0 | objY0Z1  <-objZ1      | objY1Z1  <-tail objZ1
            ]| z0<-pZs | z1'<-tail pZs | mB'  <-midsY | mBT  <-tail midsY | mA'  <-midsZ                   | objZ0    <- objV                           | objZ1    <- tail objV
            ] `using` parBuffer (max 1 $ div (fromℕ nx) forcesteps) rdeepseq

        -- (3) & (4) : get and tesselate loops
        -- FIXME: hack.
        minres = xres `min` yres `min` zres
        sqTris = [[[
            concatMap (tesselateLoop minres obj) $ getLoops $ concat [
                        segX''',
                   mapR segX''T,
                   mapR segY''',
                        segY'T',
                        segZ''',
                   mapR segZT''
                ]
             | segZ'''<- segZ''| segZT''<- segZT'
             | segY'''<- segY''| segY'T'<- segY'T
             | segX'''<- segX''| segX''T<- tail segX''

            ]| segZ'' <- segZ' | segZT' <- segZT
             | segY'' <- segY' | segY'T <- tail segY'
             | segX'' <- segX'

            ]| segZ'  <- segsZ | segZT  <- tail segsZ
             | segY'  <- segsY
             | segX'  <- segsX
            ] `using` parBuffer (max 1 $ div (fromℕ $ nx+ny+nz) forcesteps) rdeepseq

    in
      -- (5) merge squares, etc
      mergedSquareTris . concat . concat $ concat sqTris

-- | getContour gets a polyline describing the edge of a 2D object.
getContour :: ℝ2 -> ℝ2 -> ℝ2 -> Obj2 -> [Polyline]
getContour p1@(x1, y1) p2 res@(xres,yres) obj =
    let
        -- | The size of the region we're being asked to search.
        d = p2 ^-^ p1

        -- | How many steps will we take on each axis?
        nx :: ℕ
        ny :: ℕ
        (nx,ny) = ceiling `both` (d ⋯/ res)

        -- | How big are the steps?
        (rx,ry) = d ⋯/ (fromℕtoℝ `both` (nx,ny))

        -- The points inside of the region.
        pYs = [ y1 + ry*fromℕtoℝ p | p <- [0.. ny] ]
        pXs = [ x1 + rx*fromℕtoℝ p | p <- [0.. nx] ]

        -- | Performance tuning.
        -- FIXME: magic number.
        forcesteps :: Int
        forcesteps=32

        par2DList :: forall t. NFData t => ℕ -> ℕ -> ((ℕ -> ℝ) -> ℕ -> (ℕ -> ℝ) -> ℕ -> t) -> [[t]]
        par2DList lenx leny f =
            [[ f
                (\n -> x1 + rx*fromℕtoℝ (mx+n)) mx
                (\n -> y1 + ry*fromℕtoℝ (my+n)) my
                  | mx <- [0..lenx]
                ] | my <- [0..leny]
                ] `using` parBuffer (max 1 $ div (fromℕ $ lenx+leny) forcesteps) rdeepseq

        -- | Fully evaluate obj to avoid waste in mids, segs, later.
        objV = par2DList (nx+2) (ny+2) $ \x _ y _ -> obj (x 0, y 0)

        -- | Calculate mid points on X, and Y axis in 2D space.
        midsY = [[
                 interpolate (y0, objX0Y0) (y1', objX0Y1) (obj $* x0) yres
                 | x0 <- pXs |                   objX0Y0 <- objY0   | objX0Y1 <- objY1
                ]| y0 <- pYs | y1' <- tail pYs | objY0   <- objV    | objY1   <- tail objV
                ] `using` parBuffer (max 1 $ div (fromℕ ny) forcesteps) rdeepseq

        midsX = [[
                 interpolate (x0, objX0Y0) (x1', objX1Y0) (obj *$ y0) xres
                 | x0 <- pXs | x1' <- tail pXs | objX0Y0 <- objY0 | objX1Y0 <- tail objY0
                ]| y0 <- pYs |                   objY0   <- objV
                ] `using` parBuffer (max 1 $ div (fromℕ nx) forcesteps) rdeepseq

        -- | Calculate segments for each side
        segs = [[
            getSegs (x0,y0) (x1',y1') obj (objX0Y0, objX1Y0, objX0Y1, objX1Y1) (midA0, midA1, midB0, midB1)
             | x0<-pXs | x1'<-tail pXs |midB0<-mX''  | midB1<-mX'T       | midA0<-mY''  | midA1<-tail mY'' | objX0Y0<-objY0 | objX1Y0<-tail objY0 | objX0Y1<-objY1 | objX1Y1<-tail objY1
            ]| y0<-pYs | y1'<-tail pYs |mX'' <-midsX | mX'T <-tail midsX | mY'' <-midsY                    | objY0 <- objV                        | objY1 <- tail objV
            ] `using` parBuffer (max 1 $ div (fromℕ $ nx+ny) forcesteps) rdeepseq
    in
      -- | Merge squares, etc
      cleanLoopsFromSegs . concat $ concat segs
  
-- utility functions
  
injX :: ℝ -> Polyline -> [ℝ3]
injX a (Polyline xs) = map (prepend a) xs
prepend :: ℝ -> ℝ2 -> ℝ3
prepend a (b,c) = (a,b,c)
injY :: ℝ -> Polyline -> [ℝ3]
injY a (Polyline xs) = map (insert a) xs
insert :: ℝ -> ℝ2 -> ℝ3
insert b (a,c) = (a,b,c)
injZ :: ℝ -> Polyline -> [ℝ3]
injZ a (Polyline xs) = map (postfix a) xs
postfix :: ℝ -> ℝ2 -> ℝ3
postfix c (a,b) = (a,b,c)

($**) :: Obj3 -> ℝ -> ℝ2 -> ℝ
f $** a = \(b,c) -> f (a,b,c)
infixr 0 $**

(*$*) :: Obj3 -> ℝ -> ℝ2 -> ℝ
f *$* b = \(a,c) -> f (a,b,c)
infixr 0 *$*

(**$) :: Obj3 -> ℝ -> ℝ2 -> ℝ
f **$ c = \(a,b) -> f (a,b,c)
infixr 0 **$

($*) :: Obj2 -> ℝ -> ℝ -> ℝ
f $* a = \b -> f (a,b)
infixr 0 $*

(*$) :: Obj2 -> ℝ -> ℝ -> ℝ
f *$ b = \a -> f (a,b)
infixr 0 *$

appABC :: Obj3 -> ℝ -> ℝ -> ℝ -> ℝ
appABC f a b c = f (a,b,c)
appBCA :: Obj3 -> ℝ -> ℝ -> ℝ -> ℝ
appBCA f b c a = f (a,b,c)
appACB :: Obj3 -> ℝ -> ℝ -> ℝ -> ℝ
appACB f a c b = f (a,b,c)

mapR :: [[ℝ3]] -> [[ℝ3]]
mapR = map reverse

