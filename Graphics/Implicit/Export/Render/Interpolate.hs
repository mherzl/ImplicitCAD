-- Implicit CAD. Copyright (C) 2011, Christopher Olah (chris@colah.ca)
-- Copyright (C) 2016, Julia Longtin (julial@turinglace.com)
-- Released under the GNU AGPLV3+, see LICENSE

-- Allow us to use explicit foralls when writing function type declarations.
{-# LANGUAGE ExplicitForAll #-}

module Graphics.Implicit.Export.Render.Interpolate (interpolate) where

import Prelude((*), (>), (<), (/=), (+), (-), (/), (==), (&&), abs)

import Graphics.Implicit.Definitions (ℝ, Fastℕ, ℝ2)

default (Fastℕ, ℝ)
-- Consider a function f(x):

{-
   |   \        f(x)
   |    - \
   |_______\________ x
            |
             \
-}

-- The purpose of interpolate is to find the value of x where f(x) crosses zero.
-- This should be accomplished cheaply and accurately.

-- We are given the constraint that x will be between a and b.

-- We are also given the values of f at a and b: aval and bval.

-- Additionaly, we get f (continuous and differentiable almost everywhere),
-- and the resolution of the object (so that we can make decisions about
-- how precise we need to be).

-- While the output will never be used, interpolate will be called
-- in cases where f(x) doesn't cross zero (ie. aval and bval are both
-- positive or negative.

-- Clarification: If f(x) crosses zero, but doesn't necessarily have
-- to do so by intermediate value theorem, it is beyond the scope of this
-- function.

-- If it doesn't cross zero, we don't actually care what answer we give,
-- just that it's cheap.

-- FIXME: accept resolution on multiple axises.

interpolate :: ℝ2 -> ℝ2 -> (ℝ -> ℝ) -> ℝ -> ℝ
interpolate (a,aval) (_,bval) _ _ | aval*bval > 0 = a

-- The obvious:
interpolate (a, 0) _ _ _  = a
interpolate _ (b, 0) _ _  = b

-- It may seem, at first, that our task is trivial.
-- Just use linear interpolation!
-- Unfortunately, there's a nasty failure case

{-                   /
                    /
  ________#________/____
  ________________/
-}

-- This is really common for us, for example in cubes,
-- where another variable dominates.

-- It may even be the case that, because we are so close
-- to the side, it looks like we are really close to an
-- answer... And we just give it back.

-- So we need to detect this. And get free goodies while we're
-- at it (shrink domain to guess within fromm (a,b) to (a',b'))
-- :)

{-interpolate (a,aval) (b,bval) f res =
    let
        -- a' and b' are just a and b shifted inwards slightly.
        a' = (a*95+5*b)/100
        b' = (b*95+5*a)/100
        -- we evaluate at them.
        a'val = f a'
        b'val = f b'
        -- ... so we can calculate the derivatives!
        deriva = abs $ 20*(aval - a'val)
        derivb = abs $ 20*(bval - b'val)
        -- And if one side of the function is slow...
    in if abs deriva < 0.1 || abs derivb < 0.1
    -- We use a binary search interpolation!
    then
        -- The best case is that it crosses between a and a'
        if aval*a'val < 0
        then
            interpolateBin 0 (a,aval) (a',a'val) f
        -- Or between b' and b
        else if bval*b'val < 0
        then interpolateBin 0 (b',b'val) (b,bval) f
        -- But in the worst case, we get to shrink to (a',b') :)
        else interpolateBin 0 (a',a'val) (b',b'val) f
    -- Otherwise, we use our friend, linear interpolation!
    else
        -- again...
        -- The best case is that it crosses between a and a'
        if aval*a'val < 0
        then
            interpolateLin 0 (a,aval) (a',a'val) f
        -- Or between b' and b
        else if bval*b'val < 0
        then interpolateLin 0 (b',b'val) (b,bval) f
        -- But in the worst case, we get to shrink to (a',b') :)
        else interpolateLin 0 (a',a'val) (b',b'val) f
-}

interpolate (a,aval) (b,bval) f _ =
    -- Make sure aval > bval, then pass to interpolateLin
    if aval > bval
    then interpolateLin 0 (a,aval) (b,bval) f
    else interpolateLin 0 (b,bval) (a,aval) f

-- Yay, linear interpolation!

-- Try the answer linear interpolation gives us...
-- (n is to cut us off if recursion goes too deep)
interpolateLin :: Fastℕ -> ℝ2 -> ℝ2 -> (ℝ -> ℝ) -> ℝ
interpolateLin n (a, aval) (b, bval) obj | aval /= bval=
    let
        -- Interpolate and evaluate
        mid :: ℝ
        mid = a + (b-a)*aval/(aval-bval)
        midval = obj mid
    -- Are we done?
    in if midval == 0
    then mid
    -- 
    else let
        (a', a'val, b', b'val, improveRatio) =
            if midval > 0
                then (mid, midval, b, bval, midval/aval)
                else (a, aval, mid, midval, midval/bval)

    -- some times linear interpolate doesn't work,
    -- because one side is very close to zero and flat
    -- we catch it because the interval won't shrink when
    -- this is the case. To test this, we look at whether
    -- the replaced point evaluates to substantially closer
    -- to zero than the previous one.
    in if improveRatio < 0.3 && n < 4
    -- And we continue on.
    then interpolateLin (n+1) (a', a'val) (b', b'val) obj
    -- But if not, we switch to binary interpolate, which is
    -- immune to this problem
    else interpolateBin (n+1) (a', a'val) (b', b'val) obj

-- And a fallback:
interpolateLin _ (a, _) _ _ = a

-- Now for binary searching!
interpolateBin :: Fastℕ -> ℝ2 -> ℝ2 -> (ℝ -> ℝ) -> ℝ

-- The termination case:

interpolateBin 5 (a,aval) (b,bval) _ =
    if abs aval < abs bval
    then a
    else b

-- Otherwise, have fun with mid!

interpolateBin n (a,aval) (b,bval) f =
    let
        mid :: ℝ
        mid = (a+b)/2
        midval = f mid
    in if midval > 0
    then interpolateBin (n+1) (mid,midval) (b,bval) f
    else interpolateBin (n+1) (a,aval) (mid,midval) f

