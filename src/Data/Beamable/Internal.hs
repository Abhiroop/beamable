{-# OPTIONS -Wall #-}
{-# LANGUAGE DeriveGeneric, TypeOperators, FlexibleContexts, DefaultSignatures #-}
{-# LANGUAGE FlexibleInstances, ScopedTypeVariables, BangPatterns #-}
{-# LANGUAGE DoAndIfThenElse #-}

module Data.Beamable.Internal
    ( Beamable
    , beamIt
    , unbeamIt
    , typeSign
    ) where

import Data.Beamable.Util

import Blaze.ByteString.Builder
import Data.Digest.Murmur64

import Control.Arrow (first)
import Data.Bits ((.|.), (.&.), shift, testBit)
import Data.ByteString (ByteString)
import Data.Char (ord, chr)
import Data.Int (Int8, Int16, Int32, Int64)
import Data.List (unfoldr)
import Data.Monoid (mempty, mappend, mconcat)
import Data.Word (Word, Word8, Word16, Word32, Word64)
import Foreign.Storable
import GHC.Generics
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL


class Beamable a where
    -- | Serialize value into 'Builder'
    beamIt :: a -> Builder
    -- | Deserialize next value from 'ByteString', also returns leftovers
    unbeamIt :: ByteString -> (a, ByteString)
    -- | Get value's type signature, should work fine on 'undefined' values
    typeSign :: a -> Word64

    -- by default let's use generic version

    default beamIt :: (Generic a, GBeamable (Rep a)) => a -> Builder
    beamIt v = gbeamIt (from v) (0,0)

    default unbeamIt :: (Generic a, GBeamable (Rep a)) => ByteString -> (a, ByteString)
    unbeamIt v = first to $ gunbeamIt v (0,0)

    default typeSign :: (Generic a, GBeamable (Rep a)) => a -> Word64
    typeSign v = gtypeSign (from v)


signMur :: Hashable64 a => a -> Word64
signMur !a = asWord64 $ hash64 a

-- | It's possible to beam arbitrary Storable instances (not very size efficient)
beamStorable :: Storable a => a -> Builder-- {{{
beamStorable = fromStorable

unbeamStorable :: Storable a => ByteString -> (a, ByteString)
unbeamStorable bs = let v = peekBS bs in (v, B.drop (sizeOf v) bs)-- }}}

-- | It's possible to beam arbitrary Enum instances
beamEnum :: Enum a => a -> Builder-- {{{
beamEnum = beamInt . fromEnum

unbeamEnum :: Enum a => ByteString -> (a, ByteString)
unbeamEnum bs = let (i, bs') = unbeamInt bs in (toEnum i, bs')-- }}}


class GBeamable f where
    gbeamIt   :: f a        -> (Int, Word) -> Builder
    gunbeamIt :: B.ByteString -> (Int, Word) -> (f a, B.ByteString)
    gtypeSign :: f a        -> Word64

-- this instance used for datatypes with single constructor only
instance (GBeamable a, Datatype d, Constructor c) => GBeamable (M1 D d (M1 C c a)) where
    gbeamIt  (M1 (M1 x)) = gbeamIt x
    gunbeamIt x = first M1 . gunbeamIt x
    gtypeSign x = signMur (datatypeName x, ':', gtypeSign (unM1 x))

-- this instance used for  datatypes with multiple constructors and
-- values are prefixed by uniq number for each constructor
instance (GBeamable a, Constructor c) => GBeamable (M1 C c a) where
    gbeamIt (M1 x) t@(_, dirs) = mappend (beamWord dirs) (gbeamIt x t)
    gunbeamIt bs = first M1 . gunbeamIt bs
    gtypeSign x = signMur (conName x, '<', gtypeSign (unM1 x))

-- this instance is needed to avoid overlapping instances with (M1 D d (M1 C c a))
instance (GBeamable a, GBeamable b) => GBeamable (M1 D c0 (a :+: b) ) where
    gbeamIt (M1 x) = gbeamIt x
    gunbeamIt bs (lev, _) = let (dirs, bs') = unbeamWord bs
                            in first M1 $ gunbeamIt bs' (lev, dirs)
    gtypeSign x = signMur (gtypeSign (unL . unM1 $ x), '|', gtypeSign (unR . unM1 $ x))

-- choose correct constructor based on the first word uncoded from the BS (dirs variable)
instance (GBeamable a, GBeamable b) => GBeamable (a :+: b) where
    gbeamIt (L1 x) (lev, dirs) = gbeamIt x (lev + 1, dirs)
    gbeamIt (R1 x) (lev, dirs) = gbeamIt x (lev + 1, dirs + 2^lev)
    gunbeamIt bs (lev, dirs) = if testBit dirs lev
                                   then first R1 $ gunbeamIt bs (lev + 1, dirs)
                                   else first L1 $ gunbeamIt bs (lev + 1, dirs)
    gtypeSign x = signMur (gtypeSign (unL x), '|', gtypeSign (unR x))

instance GBeamable a => GBeamable (M1 S c a) where
    gbeamIt (M1 x) = gbeamIt x
    gunbeamIt bs = first M1 . gunbeamIt bs
    gtypeSign ~(M1 x) = signMur ('[', gtypeSign x)

instance GBeamable U1 where
    gbeamIt _ _ = mempty
    gunbeamIt bs _ = (U1, bs)
    gtypeSign _x = signMur 'U'

instance (GBeamable a, GBeamable b) => GBeamable (a :*: b) where
    gbeamIt (x :*: y) t = gbeamIt x t `mappend` gbeamIt y t
    gunbeamIt bs t = let (ra, bs') = gunbeamIt bs t
                         (rb, bs'') = gunbeamIt bs' t
                     in (ra :*: rb, bs'')
    gtypeSign ~(x :*: y) = signMur (gtypeSign x, '*', gtypeSign y)

instance Beamable a => GBeamable (K1 i a) where
    gbeamIt (K1 x) _ = beamIt x
    gunbeamIt bs   _ = first K1 (unbeamIt bs)
    gtypeSign x = signMur ('K', typeSign (unK1 x))


{-
Beamed int representation:


1. The integer is chunked up into 7-bit groups. Each of these 7bit
chunks are encoded as a single octet.

2. All the octets except the last one has its 8th bit set.

3. 7th bit of the first octet represents sign.

3. Octets with bits 1..7 containing only 1 or 0 can be ignored when it's not affecting the sign:

0      | 0 0000000
1      | 0 0000001
63     | 0 0111111
64     | 1 0000000  0 1000000
127    | 1 0000000  0 1111111
128    | 1 0000001  0 0000000
8191   | 1 0111111  0 1111111
8192   | 1 0000000  1 1000000  0 0000000
65535  | 1 0000011  1 1111111  0 1111111
-1     | 0 1111111
-64    | 0 1000000
-65    | 1 1111111  0 0111111
-127   | 1 1111111  0 0000001
-128   | 1 1111111  0 0000000
-129   | 1 1111110  0 0111111
-8191  | 1 1000000  0 0000001
-8192  | 1 1000000  0 0000000
-8193  | 1 1111111  1 0111111  0 1111111
-}

-- This might not work well for 32bit platform
beamInt :: Int -> Builder -- {{{
beamInt 0 = fromWord8 0
beamInt n = toBldr . bitmark . reverse . unfoldr f $ n
    where
        f :: Int -> Maybe (Word8, Int)
        f 0 = Nothing
        f x = let w = fromIntegral x .&. 0x7F :: Word8
                  rest = x `shift` (negate 7)
              in Just (w, if rest == (-1) then 0 else rest)

        bitmark :: [Word8] -> [Word8]
        bitmark (w:[]) = [w]
        bitmark (w:ws) = (w .|. 0x80) : bitmark ws
        bitmark [] = []

        toBldr :: [Word8] -> Builder
        toBldr ws = let ws' = if testBit (head ws) 6
                        then if n > 0 then 0x80:ws else ws
                        else if n > 0 then ws else 0xFF:ws
                    in fromWriteList writeWord8 ws'


-- This might not work well for 32bit platform
unbeamInt :: B.ByteString -> (Int, B.ByteString)
unbeamInt bs = (fixSign (B.foldl f 0 this), rest)
    where
        f :: Int -> Word8 -> Int
        f i w = (i `shift` 7) .|. fromIntegral (w .&. 0x7F)

        fixSign :: Int -> Int
        fixSign x = x `shift` (64 - l * 7) `shift` (l * 7 - 64)

        Just lastWord = B.findIndex (not . flip testBit 7) bs
        l = lastWord + 1
        (this, rest) = B.splitAt l bs-- }}}


-- | [un]beamWord functions are a bit more efficient than [un]beamInt
-- it assumes that values are non-negative which allows more compact representation

beamWord :: Word -> Builder-- {{{
beamWord 0 = fromWord8 0
beamWord i = fromByteString . B.reverse . fst $ B.unfoldrN 10 octets (i, True)
    where
        octets :: (Word, Bool) -> Maybe (Word8, (Word, Bool))
        octets (x, isFirst)
            | x > 0 = let r = (fromIntegral (x .&. 0x7F)) .|. (if isFirst then 0 else 0x80)
                      in Just (r, (x `shift` (negate 7), False))
            | otherwise = Nothing


unbeamWord :: B.ByteString -> (Word, B.ByteString)
unbeamWord bs = (B.foldl f 0 this, rest)
    where
        f :: Word -> Word8 -> Word
        f i w = (i `shift` 7) .|. fromIntegral (w .&. 0x7F)
        
        Just lastWord = B.findIndex (not . flip testBit 7) bs
        (this, rest) = B.splitAt (lastWord + 1) bs


{-# SPECIALIZE beamWordX :: Word8 -> Builder #-}
{-# SPECIALIZE beamWordX :: Word16 -> Builder #-}
{-# SPECIALIZE beamWordX :: Word32 -> Builder #-}
{-# SPECIALIZE beamWordX :: Word64 -> Builder #-}
beamWordX :: Integral w => w -> Builder
beamWordX = beamWord . fromIntegral

{-# SPECIALIZE unbeamWordX :: B.ByteString -> (Word8, B.ByteString) #-}
{-# SPECIALIZE unbeamWordX :: B.ByteString -> (Word16, B.ByteString) #-}
{-# SPECIALIZE unbeamWordX :: B.ByteString -> (Word32, B.ByteString) #-}
{-# SPECIALIZE unbeamWordX :: B.ByteString -> (Word64, B.ByteString) #-}
unbeamWordX :: Integral w => B.ByteString -> (w, B.ByteString)
unbeamWordX bs = let (i, bs') = unbeamWord bs in (fromIntegral i, bs')-- }}}


-- (de)serialization for numbers -- {{{
instance Beamable Int    where { beamIt = beamInt ; unbeamIt = unbeamInt ; typeSign _ = signMur "Int" }
instance Beamable Int8   where { beamIt = beamEnum ; unbeamIt = unbeamEnum ; typeSign _ = signMur "Int8" }
instance Beamable Int16  where { beamIt = beamEnum ; unbeamIt = unbeamEnum ; typeSign _ = signMur "Int16" }
instance Beamable Int32  where { beamIt = beamEnum ; unbeamIt = unbeamEnum ; typeSign _ = signMur "Int32" }
instance Beamable Int64  where { beamIt = beamEnum ; unbeamIt = unbeamEnum ; typeSign _ = signMur "Int64" }
instance Beamable Word   where { beamIt = beamWord ; unbeamIt = unbeamWord ; typeSign _ = signMur "Word" }
instance Beamable Word8  where { beamIt = beamWordX ; unbeamIt = unbeamWordX ; typeSign _ = signMur "Word8" }
instance Beamable Word16 where { beamIt = beamWordX ; unbeamIt = unbeamWordX ; typeSign _ = signMur "Word16" }
instance Beamable Word32 where { beamIt = beamWordX ; unbeamIt = unbeamWordX ; typeSign _ = signMur "Word32" }
instance Beamable Word64 where { beamIt = beamWordX ; unbeamIt = unbeamWordX ; typeSign _ = signMur "Word64" }
instance Beamable Float  where { beamIt = beamStorable ; unbeamIt = unbeamStorable ; typeSign _ = signMur "Float" }
instance Beamable Double where { beamIt = beamStorable ; unbeamIt = unbeamStorable ; typeSign _ = signMur "Double" }
-- }}}

instance Beamable Char where
    beamIt = beamWord . fromIntegral . ord
    unbeamIt = first (chr . fromIntegral) . unbeamWord
    typeSign _ = signMur "Char"

-- Tuples
instance (Beamable a, Beamable b) => Beamable (a, b)
instance (Beamable a, Beamable b, Beamable c) => Beamable (a, b, c)
instance (Beamable a, Beamable b, Beamable c, Beamable d) => Beamable (a, b, c, d)
instance (Beamable a, Beamable b, Beamable c, Beamable d
         ,Beamable e) => Beamable (a, b, c, d, e)
instance (Beamable a, Beamable b, Beamable c, Beamable d
         ,Beamable e, Beamable f) => Beamable (a, b, c, d, e, f)
instance (Beamable a, Beamable b, Beamable c, Beamable d
         ,Beamable e, Beamable f, Beamable g) => Beamable (a, b, c, d, e, f, g)

instance (Beamable a, Beamable b) => Beamable (Either a b)
instance Beamable a => Beamable (Maybe a)

instance Beamable Bool

instance Beamable a => Beamable [a] where
    beamIt xs = beamInt (length xs) `mappend` mconcat (map beamIt xs)
    unbeamIt bs = let (cnt, bs') = unbeamInt bs
                  in unfoldCnt cnt unbeamIt bs'
    typeSign _ = signMur ('L', typeSign (undefined :: a))

unfoldCnt :: Int -> (b -> (a, b)) -> b -> ([a], b)
unfoldCnt cnt_i f = unfoldCnt' [] cnt_i
    where
        unfoldCnt' xs 0 b = (reverse xs, b)
        unfoldCnt' xs cnt b = let (x, b') = f b
                              in unfoldCnt' (x:xs) (cnt - 1) b'

instance Beamable ByteString where
    beamIt bs = beamInt (B.length bs) `mappend` fromByteString bs
    unbeamIt = uncurry B.splitAt . unbeamInt
    typeSign _ = signMur "ByteString.Strict"

instance Beamable BL.ByteString where
    beamIt = beamIt . BL.toChunks
    unbeamIt bs = let (chunks, bs') = unbeamIt bs
                  in (BL.fromChunks chunks, bs')
    typeSign _ = signMur "ByteString.Lazy"
