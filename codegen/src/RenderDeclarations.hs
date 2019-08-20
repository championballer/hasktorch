{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE QuasiQuotes #-}
module RenderDeclarations where

import Data.Yaml (ParseException)
import qualified Data.Yaml as Y
import Text.Shakespeare.Text (st)
import Data.Text (Text, replace)
import qualified Data.Text.IO as T
import qualified Data.Set as S
import System.Directory (createDirectoryIfMissing)

import qualified ParseDeclarations as D
import ParseFunctionSig as P
import RenderCommon

dropGenerator :: [Parameter] -> [Parameter]
dropGenerator params = filter (\v' -> ptype v' /= Ptr GeneratorType) params

addFunctionWithDefaultArguments :: D.Declaration -> [D.Declaration]
addFunctionWithDefaultArguments dl = map (\args -> dl{D.arguments = args}) genArgsWithDefault'
  where
    genArgsWithDefault [] = []
    genArgsWithDefault (x:xs) | D.default' x /= Nothing = (x:xs) : genArgsWithDefault xs
                              | otherwise = [(x:xs)]
    genArgsWithDefault' = map reverse $ genArgsWithDefault (reverse $ D.arguments dl)


toFunction :: D.Declaration -> P.Function
toFunction dl = P.Function
  { P.name = D.name dl
  , P.parameters = map (\a -> P.Parameter (D.type2type a) (D.name' a) Nothing) $ D.arguments dl
  , P.retType = case D.returns dl of
      [a] -> D.type2type a
      ax -> P.Tuple $ map D.type2type ax
  , P.variant = P.VFunction
  }

uniqFilter :: Ord n => (a -> n) -> [a] -> [a]
uniqFilter item xs = uniqFilter' xs S.empty
  where
    uniqFilter' [] _ = []
    uniqFilter' (x:xs) ids = if S.member (item x) ids then uniqFilter' xs ids else x:(uniqFilter' xs (S.insert (item x) ids))

renderFunctions :: Bool -> Bool -> String -> [D.Declaration] -> Text
renderFunctions is_managed enb_type_initials namespace nfs =
  mconcat $
  map (\nf -> functionToCpp is_managed enb_type_initials namespace "" nf) $
  uniqFilter getSignatures $
  map toFunction nfs
  
decodeAndCodeGen :: String -> String -> IO ()
decodeAndCodeGen basedir fileName = do
  funcs <- Y.decodeFileEither fileName :: IO (Either ParseException [D.Declaration])
  case funcs of
    Left err' -> print err'
    Right fns' -> do
      let fns = concat $ map addFunctionWithDefaultArguments fns' 
      createDirectoryIfMissing True (basedir <> "/ATen")
      T.writeFile (basedir <> "/ATen/Type.hs") $
        typeTemplate
      T.writeFile (basedir <> "/ATen/Managed/NN.hs") $
        template False True "ATen.Managed.NN" (renderFunctions True False "at::" (filter (\a -> D.mode a == D.NN) fns))
      T.writeFile (basedir <> "/ATen/Managed/TH.hs") $
        template False True "ATen.Managed.TH" (renderFunctions True True "at::" (filter (\a -> D.mode a == D.TH) fns))
      T.writeFile (basedir <> "/ATen/Managed/Native.hs") $
        template False True "ATen.Managed.Native" $
        renderFunctions True True "at::" (filter (\a -> D.mode a == D.Native && "namespace" `elem` (D.method_of a)) fns)
      T.writeFile (basedir <> "/ATen/Unmanaged/NN.hs") $
        template False False "ATen.Unmanaged.NN" (renderFunctions False False "at::" (filter (\a -> D.mode a == D.NN) fns))
      T.writeFile (basedir <> "/ATen/Unmanaged/TH.hs") $
        template False False "ATen.Unmanaged.TH" (renderFunctions False True "at::" (filter (\a -> D.mode a == D.TH) fns))
      T.writeFile (basedir <> "/ATen/Unmanaged/Native.hs") $
        template False False "ATen.Unmanaged.Native" $
        renderFunctions False True "at::" (filter (\a -> D.mode a == D.Native && "namespace" `elem` (D.method_of a)) fns)

      createDirectoryIfMissing True (basedir <> "/Torch/Managed")
      createDirectoryIfMissing True (basedir <> "/Torch/Unmanaged")
      T.writeFile (basedir <> "/Torch/Managed/NN.hs") $
        template True True "Torch.Managed.NN" (renderFunctions True False "torch::" (filter (\a -> D.mode a == D.NN && D.is_factory_method a == Just True) fns))
      T.writeFile (basedir <> "/Torch/Managed/TH.hs") $
        template True True "Torch.Managed.TH" (renderFunctions True True "torch::" (filter (\a -> D.mode a == D.TH && D.is_factory_method a == Just True) fns))
      T.writeFile (basedir <> "/Torch/Managed/Native.hs") $
        template True True "Torch.Managed.Native" $
        renderFunctions True True "torch::" (filter (\a -> D.mode a == D.Native && "namespace" `elem` (D.method_of a) && D.is_factory_method a == Just True) fns)
      T.writeFile (basedir <> "/Torch/Unmanaged/NN.hs") $
        template True False "Torch.Unmanaged.NN" (renderFunctions False False "torch::" (filter (\a -> D.mode a == D.NN && D.is_factory_method a == Just True) fns))
      T.writeFile (basedir <> "/Torch/Unmanaged/TH.hs") $
        template True False "Torch.Unmanaged.TH" (renderFunctions False True "torch::" (filter (\a -> D.mode a == D.TH && D.is_factory_method a == Just True) fns))
      T.writeFile (basedir <> "/Torch/Unmanaged/Native.hs") $
        template True False "Torch.Unmanaged.Native" $
        renderFunctions False True "torch::" (filter (\a -> D.mode a == D.Native && "namespace" `elem` (D.method_of a) && D.is_factory_method a == Just True) fns)




renderImport :: Bool -> Bool -> Text -> Text
renderImport is_torch_factory_method is_managed module_name =  if is_managed then  [st|
import Foreign.C.String
import Foreign.C.Types
import Foreign
import ATen.Type
import ATen.Class
import ATen.Cast
import qualified #{replace "Managed" "Unmanaged" module_name} as Unmanaged
import ATen.Unmanaged.Type.Generator
import ATen.Unmanaged.Type.IntArray
import ATen.Unmanaged.Type.Scalar
import ATen.Unmanaged.Type.Storage
import ATen.Unmanaged.Type.Tensor
import ATen.Unmanaged.Type.TensorList
import ATen.Unmanaged.Type.TensorOptions
import ATen.Unmanaged.Type.Tuple
import ATen.Unmanaged.Type.StdString
import ATen.Unmanaged.Type.StdArray
|] else [st|
import Foreign.C.String
import Foreign.C.Types
import Foreign
import ATen.Type
import ATen.Class

import qualified Language.C.Inline.Cpp as C
import qualified Language.C.Inline.Cpp.Exceptions as C
import qualified Language.C.Inline.Context as C
import qualified Language.C.Types as C
import qualified Data.Map as Map

C.context $ C.cppCtx <> mempty { C.ctxTypesTable = typeTable }

C.include "<vector>"
C.include "<ATen/ATen.h>"
|] <> if is_torch_factory_method then [st|
C.include "<torch/torch.h>"
|] else ""


template :: Bool -> Bool -> Text -> Text -> Text
template is_torch_factory_method is_managed module_name functions = [st|
-- generated by using spec/Declarations.yaml

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}

module #{module_name} where

#{renderImport is_torch_factory_method is_managed module_name}
#{functions}
|]

typeTemplate :: Text
typeTemplate = [st|
-- generated by using spec/Declarations.yaml

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}

module ATen.Type where

import qualified Language.C.Inline.Cpp as C
import qualified Language.C.Inline.Cpp.Exceptions as C
import qualified Language.C.Inline.Context as C
import qualified Language.C.Types as C
import qualified Data.Map as Map

import Foreign.C.String
import Foreign.C.Types
import Foreign

type ScalarType = Int8
type DeviceType = Int16
type Backend = CInt
type Layout = Int8
type MemoryFormat = Int8
type QScheme = Int8

data Tensor
data Scalar
data TensorOptions
data TensorList
data IntArrayRef
data IntArray
data TensorAVector
data Storage
data StdArray a b
data StdString
data Generator
data Device
data Context
data ConstQuantizerPtr

typeTable = Map.fromList [
        (C.TypeName "at::Scalar", #{bra}t|Scalar|#{cket})
      , (C.TypeName "at::Tensor", #{bra}t|Tensor|#{cket})
      , (C.TypeName "at::TensorOptions", #{bra}t|TensorOptions|#{cket})
      , (C.TypeName "std::vector<at::Tensor>", #{bra}t|TensorList|#{cket})
      , (C.TypeName "at::IntArrayRef", #{bra}t|IntArrayRef|#{cket})
      , (C.TypeName "std::vector<int64_t>", #{bra}t|IntArray|#{cket})
      , (C.TypeName "at::ScalarType", #{bra}t|ScalarType|#{cket})
      , (C.TypeName "at::DeviceType", #{bra}t|DeviceType|#{cket})
      , (C.TypeName "at::Storage", #{bra}t|Storage|#{cket})
      , (C.TypeName "at::Device", #{bra}t|Device|#{cket})
      , (C.TypeName "at::Generator", #{bra}t|Generator|#{cket})
      , (C.TypeName "std::string", #{bra}t|StdString|#{cket})
      , (C.TypeName "std::array<bool,2>", #{bra}t|StdArray CBool 2|#{cket})
      , (C.TypeName "std::array<bool,3>", #{bra}t|StdArray CBool 3|#{cket})
      , (C.TypeName "std::array<bool,4>", #{bra}t|StdArray CBool 4|#{cket})
      , (C.TypeName "std::tuple<at::Tensor,at::Tensor>", #{bra}t|(Tensor,Tensor)|#{cket})
      , (C.TypeName "std::tuple<at::Tensor,at::Tensor,at::Tensor>", #{bra}t|(Tensor,Tensor,Tensor)|#{cket})
      , (C.TypeName "std::tuple<at::Tensor,at::Tensor,at::Tensor,at::Tensor>", #{bra}t|(Tensor,Tensor,Tensor,Tensor)|#{cket})
      , (C.TypeName "std::tuple<at::Tensor,at::Tensor,at::Tensor,at::Tensor,at::Tensor>", #{bra}t|(Tensor,Tensor,Tensor,Tensor,Tensor)|#{cket})
      , (C.TypeName "std::tuple<at::Tensor,at::Tensor,at::Tensor,std::vector<at::Tensor>>", #{bra}t|(Tensor,Tensor,Tensor,TensorList)|#{cket})
      , (C.TypeName "std::tuple<at::Tensor,at::Tensor,double,int64_t>", #{bra}t|(Tensor,Tensor,CDouble,Int64)|#{cket})
      , (C.TypeName "std::tuple<at::Tensor,at::Tensor,float,int>", #{bra}t|(Tensor,Tensor,CFloat,CInt)|#{cket})
      , (C.TypeName "std::tuple<at::Tensor,at::Tensor,at::Tensor,int64_t>", #{bra}t|(Tensor,Tensor,Tensor,Int64)|#{cket})
      , (C.TypeName "at::Backend", #{bra}t|Backend|#{cket})
      , (C.TypeName "at::Layout", #{bra}t|Layout|#{cket})
      , (C.TypeName "at::MemoryFormat", #{bra}t|MemoryFormat|#{cket})
      , (C.TypeName "at::Context", #{bra}t|Context|#{cket})
      , (C.TypeName "at::ConstQuantizerPtr", #{bra}t|ConstQuantizerPtr|#{cket})
    ]
|]
