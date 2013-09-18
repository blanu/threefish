{-# LANGUAGE BangPatterns #-}
-- | 256 and 512 bit Skein. Only "normal" hashing and Skein-MAC are supported;
--   no tree hashing, weird output lengths or other curiosities.
module Crypto.Skein (
    Skein (..), Block512 (..), Block256 (..), Key512, Key256
  ) where
import qualified Data.ByteString as BS
import Data.ByteString.Unsafe
import System.IO.Unsafe
import Foreign.Ptr
import Crypto.Cipher.Threefish.Threefish256
import Crypto.Cipher.Threefish.Threefish512
import Crypto.Cipher.Threefish.Common
import Crypto.Cipher.Threefish.UBI
import Data.Bits
import Data.Serialize
import Data.List (foldl')
import Data.Word
import Data.Serialize

class Skein a where
  -- | Calculate the Skein-MAC of a message. Keys may be created by
  --   de-serializing a ByteString or by constructing stitching together 4/8
  --   Word64 in a Block256/Block512.
  skeinMAC :: a -> BS.ByteString -> a
  -- | Calculate the Skein checksum of a message.
  skein :: BS.ByteString -> a

config256 :: Block256
config256 = Block256 0x0000000133414853 256 0 0

{-# INLINE xb256 #-}
xb256 :: Block256 -> Block256 -> Block256
xb256 (Block256 x1 x2 x3 x4) (Block256 y1 y2 y3 y4) =
  Block256 (x1 `xor` y1) (x2 `xor` y2) (x3 `xor` y3) (x4 `xor` y4)

-- | Initial state for Skein256
init256 :: Key256 -> Block256
init256 key = fst $ processBlock256 32 key configTweak config256

zero256 :: Block256
zero256 = Block256 0 0 0 0

{-# INLINE processBlock256 #-}
-- | Process a single block of Skein 256. Call on Threefish, XOR the cryptotext
--   with the plaintext and update the tweak.
processBlock256 :: Word64 -> Key256 -> Tweak -> Block256 -> (Key256, Tweak)
processBlock256 !len !key !tweak !block =
    (encrypt256 key tweak' block `xb256` block, setFirst False tweak')
  where
    !tweak' = addBytes len tweak

-- | Hash a message using a particular key. For normal hashing, use all zeroes;
--   for Skein-MAC, use the MAC key.
hash256 :: Key256 -> BS.ByteString -> Block256
hash256 !key !bs =
    unsafePerformIO $ unsafeUseAsCString bs' $ \ptr -> do
      processBlocks (castPtr ptr) 0 (init256 key) (newTweak Message)
  where
    !len = BS.length bs
    !lastN = len `quot` 8 - 4
    !lastLen = case len `rem` 32 of 0 -> 32 ; n -> n
    !lastLenW64 = fromIntegral lastLen
    !bs' = BS.append bs (BS.pack $ replicate (32-lastLen) 0)
    processBlocks !ptr =
        go
      where
        go !n !key !tweak
          | n < lastN = do
            block <- readBlock256 ptr n
            case processBlock256 32 key tweak block of
              (block', tweak') -> go (n+4) block' tweak'
          | otherwise = do
            block <- readBlock256 ptr n
            let tweak' = setLast True tweak
                (block', _) = processBlock256 lastLenW64 key tweak' block
                finalTweak = setLast True $ newTweak Output
                (b,_) = processBlock256 8 block' finalTweak zero256
            return b

{-# INLINE skein256 #-}
-- | Hash a message using 256 bit Skein.
skein256 :: BS.ByteString -> Block256
skein256 = hash256 zero256

{-# INLINE skeinMAC256 #-}
-- | Create a 256 bit Skein-MAC.
skeinMAC256 :: Key256 -> BS.ByteString -> Block256
skeinMAC256 = undefined
  hash256 . fst . processBlock256 32 zero256 (setLast True $ newTweak Key)

instance Skein Block256 where
  skeinMAC = skeinMAC256
  skein    = skein256



---------------------
-- 512 bit version --
---------------------

-- TODO: clean this up using type classes and stuff; way too copy-pasty!

config512 :: Block512
config512 = Block512 0x0000000133414853 512 0 0 0 0 0 0

{-# INLINE xb512 #-}
xb512 :: Block512 -> Block512 -> Block512
xb512 (Block512 x1 x2 x3 x4 x5 x6 x7 x8)
      (Block512 y1 y2 y3 y4 y5 y6 y7 y8) =
  Block512 (x1 `xor` y1) (x2 `xor` y2) (x3 `xor` y3) (x4 `xor` y4)
           (x5 `xor` y5) (x6 `xor` y6) (x7 `xor` y7) (x8 `xor` y8)

-- | Initial state for Skein512
init512 :: Key512 -> Block512
init512 key = fst $ processBlock512 32 key configTweak config512

zero512 :: Block512
zero512 = Block512 0 0 0 0 0 0 0 0

{-# INLINE processBlock512 #-}
-- | Process a single block of Skein 512. Call on Threefish, XOR the cryptotext
--   with the plaintext and update the tweak.
processBlock512 :: Word64 -> Key512 -> Tweak -> Block512 -> (Key512, Tweak)
processBlock512 !len !key !tweak !block =
    (encrypt512 key tweak' block `xb512` block, setFirst False tweak')
  where
    !tweak' = addBytes len tweak

-- | Hash a message using a particular key. For normal hashing, use all zeroes;
--   for Skein-MAC, use the MAC key.
hash512 :: Key512 -> BS.ByteString -> Block512
hash512 !key !bs =
    case flip runGet bs' $ go len (init512 key) (newTweak Message) of
      Right x -> x
  where
    !len = BS.length bs
    !lastLen = case len `rem` 64 of 0 -> 64 ; n -> n
    !lastLenW64 = fromIntegral lastLen
    !bs' = BS.append bs (BS.pack $ replicate (64-lastLen) 0)
    go !n !key !tweak
      | n > 64 = do
        block <- get
        let (block', tweak') = processBlock512 64 key tweak block
        go (n-64) block' tweak'
      | otherwise = do
        block <- get
        let tweak' = setLast True tweak
            (block', _) = processBlock512 lastLenW64 key tweak' block
            finalTweak = setLast True $ newTweak Output
            (b,_) = processBlock512 8 block' finalTweak zero512
        return b

{-# INLINE skein512 #-}
-- | Hash a message using 512 bit Skein.
skein512 :: BS.ByteString -> Block512
skein512 = hash512 zero512

{-# INLINE skeinMAC512 #-}
-- | Create a 512 bit Skein-MAC.
skeinMAC512 :: Key512 -> BS.ByteString -> Block512
skeinMAC512 =
  hash512 . fst . processBlock512 64 zero512 (setLast True $ newTweak Key)

instance Skein Block512 where
  skeinMAC = skeinMAC512
  skein    = skein512
