--------------------------------------------------------------------
-- |
-- Module    :  TypeCheck.Encode
-- Copyright :  (c) Zach Kimberg 2019
-- License   :  MIT
-- Maintainer:  zachary@kimberg.com
-- Stability :  experimental
-- Portability: non-portable
--
--------------------------------------------------------------------

module TypeCheck.Encode where

import           Control.Monad
import Data.Hashable (Hashable)
import qualified Data.HashMap.Strict as H
import qualified Data.IntMap.Lazy as IM

import           Syntax.Types
import           Syntax.Prgm
import           Syntax
import           TypeCheck.Common
import           TypeCheck.TypeGraph (buildTypeEnv)

makeBaseFEnv :: FEnv
makeBaseFEnv = FEnv IM.empty [] ((0, 0), H.empty) H.empty []

fromMetaP :: FEnv -> PreMeta -> String -> TypeCheckResult (VarMeta, Pnt, FEnv)
fromMetaP env m description  = case metaTypeVar m of
  Just _ -> do
    let (p, env') = fresh env (TypeCheckResult [] $ SType TopType bottomType description)
    return (VarMeta p m, p, env')
  Nothing -> do
    let (p, env') = fresh env (TypeCheckResult [] $ SType (getMetaType m) bottomType description)
    return (VarMeta p m, p, env')

fromMeta :: FEnv -> PreMeta -> String -> TypeCheckResult (VarMeta, FEnv)
fromMeta env m description = do
  (m', _, env') <- fromMetaP env m description
  return (m', env')

mapMWithFEnv :: FEnv -> (FEnv -> a -> TypeCheckResult (b, FEnv)) -> [a] -> TypeCheckResult ([b], FEnv)
mapMWithFEnv env f = foldM f' ([], env)
  where f' (acc, e) a = do
          (b, e') <- f e a
          return (b:acc, e')

mapMWithFEnvMap :: (Eq k, Hashable k) => FEnv -> (FEnv -> a -> TypeCheckResult (b, FEnv)) -> H.HashMap k a -> TypeCheckResult (H.HashMap k b, FEnv)
mapMWithFEnvMap env f hmap = do
  (res, env2) <- mapMWithFEnv env f' (H.toList hmap)
  return (H.fromList res, env2)
  where
    f' e (k, a) = do
      (b, e2) <- f e a
      return ((k, b), e2)

mapMWithFEnvMapWithKey :: (Eq k, Hashable k) => FEnv -> (FEnv -> (k, a) -> TypeCheckResult ((k, b), FEnv)) -> H.HashMap k a -> TypeCheckResult (H.HashMap k b, FEnv)
mapMWithFEnvMapWithKey env f hmap = do
  (res, env2) <- mapMWithFEnv env f' (H.toList hmap)
  return (H.fromList res, env2)
  where
    f' e (k, a) = do
      ((k2, b), e2) <- f e (k, a)
      return ((k2, b), e2)

fromExpr :: VArgMetaMap-> FEnv -> PExpr -> TypeCheckResult (VExpr, FEnv)
fromExpr _ env (CExpr m (CInt i)) = do
  (m', p, env') <- fromMetaP env m ("Constant int " ++ show i)
  return (CExpr m' (CInt i), addConstraints env' [EqualsKnown p intType])
fromExpr _ env (CExpr m (CFloat f)) = do
  (m', p, env') <- fromMetaP env m ("Constant float " ++ show f)
  return (CExpr m' (CFloat f), addConstraints env' [EqualsKnown p floatType])
fromExpr _ env (CExpr m (CStr s)) = do
  (m', p, env') <- fromMetaP env m ("Constant str " ++ s)
  return (CExpr m' (CStr s), addConstraints env' [EqualsKnown p strType])
fromExpr _ env1 (Value m name) = do
  (m', p, env2) <- fromMetaP env1 m ("Value " ++ name)
  lookupM <- fLookup env2 name
  return (Value m' name, addConstraints env2 [EqPoints p (getPnt lookupM)])
fromExpr objArgs env1 (Arg m name) = do
  (m', p, env2) <- fromMetaP env1 m ("Arg " ++ name)
  case H.lookup name objArgs of
    Nothing -> error $ "Could not find arg " ++ name
    Just lookupArg ->
      return (Arg m' name, addConstraints env2 [EqPoints p (getPnt lookupArg)])
fromExpr objArgs env1 (TupleApply m (baseM, baseExpr) args) = do
  (m', p, env2) <- fromMetaP env1 m "TupleApply Meta"
  (baseM', baseP, env3) <- fromMetaP env2 baseM "TupleApply BaseMeta"
  (baseExpr', env4) <- fromExpr objArgs env3 baseExpr
  (args', env5) <- mapMWithFEnvMap env4 (fromExpr objArgs) args
  (convertExprMetas, env6) <- mapMWithFEnvMap env5 (\e _ -> return $ fresh e (TypeCheckResult [] $ SType TopType bottomType "Tuple converted expr meta")) args
  let arrowArgConstraints = H.elems $ H.intersectionWith ArrowTo (fmap getPntExpr args') convertExprMetas
  let tupleConstraints = H.elems $ H.mapWithKey (\name ceMeta -> PropEq (p, name) ceMeta) convertExprMetas
  let constraints = [ArrowTo (getPntExpr baseExpr') baseP, AddArgs (baseP, H.keysSet args) p, BoundedByObjs BoundAllObjs p] ++ arrowArgConstraints ++ tupleConstraints
  let env7 = addConstraints env6 constraints
  return (TupleApply m' (baseM', baseExpr') args', env7)

fromAnnot :: VArgMetaMap -> FEnv -> PCompAnnot -> TypeCheckResult (VCompAnnot, FEnv)
fromAnnot objArgs env1 (CompAnnot name args) = do
  (args', env2) <- mapMWithFEnvMap env1 (fromExpr objArgs) args
  return (CompAnnot name args', env2)

fromGuard :: VArgMetaMap -> FEnv -> PGuard -> TypeCheckResult (VGuard, FEnv)
fromGuard objArgs env1 (IfGuard expr) =  do
  (expr', env2) <- fromExpr objArgs env1 expr
  let (bool, env3) = fresh env2 $ TypeCheckResult [] $ SType boolType bottomType "bool"
  return (IfGuard expr', addConstraints env3 [ArrowTo (getPnt $ getExprMeta expr') bool])
fromGuard _ env ElseGuard = return (ElseGuard, env)
fromGuard _ env NoGuard = return (NoGuard, env)

fromArrow :: VObject -> FEnv -> PArrow -> TypeCheckResult (VArrow, FEnv)
fromArrow obj@(Object _ _ objName objVars _) env1 (Arrow m annots aguard maybeExpr) = do
  (m', p, env2) <- fromMetaP env1 m ("Arrow result from " ++ show objName)
  let argMetaMap = formArgMetaMap obj
  (annots', env3) <- mapMWithFEnv env2 (fromAnnot argMetaMap) annots
  (aguard', env4) <- fromGuard argMetaMap env3 aguard
  case maybeExpr of
    Just expr -> do
      (vExpr, env5) <- fromExpr argMetaMap env4 expr
      let env6 = case metaTypeVar m of
            Just typeVarName -> case H.lookup typeVarName objVars of
              Just varM -> addConstraints env5 [ArrowTo (getPntExpr vExpr) (getPnt varM), EqPoints (getPnt varM) p]
              Nothing -> error "unknown type var"
            Nothing -> addConstraints env5 [ArrowTo (getPntExpr vExpr) p]
      let arrow' = Arrow m' annots' aguard' (Just vExpr)
      let env7 = fAddTypeGraph env6 objName (obj, arrow')
      return (arrow', env7)
    Nothing -> return (Arrow m' annots' aguard' Nothing, env4)

fromObjectMap :: FEnv -> (VObject, [PArrow]) -> TypeCheckResult ((VObject, [VArrow]), FEnv)
fromObjectMap env1 (obj, arrows) = do
  (arrows', env2) <- mapMWithFEnv env1 (fromArrow obj) arrows
  return ((obj, arrows'), env2)

fromObjVar :: String -> FEnv -> (TypeVarName, PreMeta) -> TypeCheckResult ((TypeVarName, VarMeta), FEnv)
fromObjVar prefix env1 (varName, m) = do
  (m', env2) <- fromMeta env1 m (prefix ++ "." ++ varName)
  return ((varName, m'), env2)

addObjArg :: VarMeta -> String -> H.HashMap TypeVarName VarMeta -> FEnv -> (TypeName, PObjArg) -> TypeCheckResult ((TypeName, VObjArg), FEnv)
addObjArg objM prefix varMap env (n, (m, maybeSubObj)) = do
  let prefix' = prefix ++ "." ++ n
  (m', env2) <- fromMeta env m prefix'
  let env3 = addConstraints env2 [PropEq (getPnt objM, n) (getPnt m'), BoundedByObjs BoundTypeObjs (getPnt m')]
  let env4 = case H.lookup n varMap of
        Just varM -> addConstraints env3 [EqPoints (getPnt m') (getPnt varM)]
        Nothing -> env3
  case maybeSubObj of
    Just subObj -> do
      (subObj'@(Object subM _ _ _ _), env5) <- fromObject prefix' env4 subObj
      return ((n, (m', Just subObj')), addConstraints env5 [ArrowTo (getPnt subM) (getPnt m')])
    Nothing -> return ((n, (m', Nothing)), env4)

fromObject :: String -> FEnv -> PObject -> TypeCheckResult (VObject, FEnv)
fromObject prefix env (Object m basis name vars args) = do
  let prefix' = prefix ++ "." ++ name
  (m', env1) <- fromMeta env m prefix'
  (vars', env2) <- mapMWithFEnvMapWithKey env1 (fromObjVar prefix') vars
  (args', env3) <- mapMWithFEnvMapWithKey env2 (addObjArg m' prefix' vars') args
  let obj' = Object m' basis name vars' args'
  (objValue, env4) <- fromMeta env3 (PreTyped $ SumType $ joinPartialLeafs [(name, H.empty, H.empty)]) ("objValue" ++ name)
  let env5 = fInsert env4 name objValue
  let env6 = addConstraints env5 [BoundedByObjs BoundAllObjs (getPnt m')]
  let env7 = addConstraints env6 [BoundedByKnown (getPnt m') (SumType $ joinPartialLeafs [(name, fmap (const TopType) vars, fmap (const TopType) args)]) | basis /= PatternObj]
  return (obj', env7)

-- Add all of the objects first for various expressions that call other top level functions
fromObjectArrows :: FEnv -> (PObject, [PArrow]) -> TypeCheckResult ((VObject, [PArrow]), FEnv)
fromObjectArrows env (obj, arrows) = do
  (obj', env1) <- fromObject "Object" env obj
  return ((obj', arrows), env1)

fromPrgm :: FEnv -> PPrgm -> TypeCheckResult (VPrgm, FEnv)
fromPrgm env1 (objMap1, classMap) = do
  (objMap2, env2) <- mapMWithFEnv env1 fromObjectArrows $ H.toList objMap1
  (objMap3, env3) <- mapMWithFEnv env2 fromObjectMap objMap2
  let env4 = buildTypeEnv env3 objMap3
  return ((objMap3, classMap), env4)
