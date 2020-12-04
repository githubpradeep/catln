--------------------------------------------------------------------
-- |
-- Module    :  TypeCheck.Common
-- Copyright :  (c) Zach Kimberg 2019
-- License   :  MIT
-- Maintainer:  zachary@kimberg.com
-- Stability :  experimental
-- Portability: non-portable
--
--------------------------------------------------------------------

{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE NamedFieldPuns #-}

module TypeCheck.Common where

import qualified Data.HashMap.Strict as H
import qualified Data.IntMap.Lazy as IM
import           Data.Hashable
import           Data.List
import           GHC.Generics          (Generic)

import           Syntax.Types
import           Syntax.Prgm
import           Syntax
import           Text.Printf
import Data.Aeson (ToJSON)

data TypeCheckError
  = GenTypeCheckError String
  | AbandonCon SConstraint
  | TupleMismatch TypedMeta TExpr Typed (H.HashMap String TExpr)
  | TCWithMatchingConstraints [SConstraint] TypeCheckError
  deriving (Eq, Ord, Generic, Hashable, ToJSON)

type SplitSType = (Type, Type, String)
data SType
  = SType Type Type String -- SType upper lower (description in type)
  | SVar TypeVarAux VarMeta
  deriving (Eq, Ord, Generic, Hashable, ToJSON)
type Scheme = TypeCheckResult SType

type Pnt = Int

type EnvValMap = (H.HashMap String VarMeta)
data FEnv = FEnv { fePnts :: IM.IntMap Scheme
                 , feCons :: [Constraint]
                 , feUnionAllObjs :: VarMeta -- union of all TypeObj for argument inference
                 , feUnionTypeObjs :: VarMeta -- union of all Object types for function limiting
                 , feTypeGraph :: TypeGraph
                 , feClassMap :: ClassMap
                 , feDefMap :: EnvValMap
                 , feTrace :: TraceConstrain
                 } deriving (Eq, Show)

type UnionObj = (Pnt, Pnt) -- a union of all TypeObj for argument inference, union of all Object types for function limiting

data BoundObjs = BoundAllObjs | BoundTypeObjs
  deriving (Eq, Ord, Show, Generic, Hashable, ToJSON)

data Constraint
  = EqualsKnown VarMeta Type
  | EqPoints VarMeta VarMeta
  | BoundedByKnown VarMeta Type
  | BoundedByObjs BoundObjs VarMeta
  | ArrowTo VarMeta VarMeta -- ArrowTo src dest
  | PropEq (VarMeta, ArgName) VarMeta
  | VarEq (VarMeta, TypeVarName) VarMeta
  | AddArg (VarMeta, String) VarMeta
  | AddInferArg VarMeta VarMeta -- AddInferArg base arg
  | PowersetTo VarMeta VarMeta
  | UnionOf VarMeta [VarMeta]
  deriving (Eq, Show, Generic, ToJSON)

data SConstraint
  = SEqualsKnown Scheme Type
  | SEqPoints Scheme Scheme
  | SBoundedByKnown Scheme Type
  | SBoundedByObjs BoundObjs Scheme
  | SArrowTo Scheme Scheme
  | SPropEq (Scheme, ArgName) Scheme
  | SVarEq (Scheme, TypeVarName) Scheme
  | SAddArg (Scheme, String) Scheme
  | SAddInferArg Scheme Scheme
  | SPowersetTo Scheme Scheme
  | SUnionOf Scheme [Scheme]
  deriving (Eq, Ord, Generic, Hashable, ToJSON)

data TypeCheckResult r
  = TypeCheckResult [TypeCheckError] r
  | TypeCheckResE [TypeCheckError]
  deriving (Eq, Ord, Generic, Hashable, ToJSON)

getTCRE :: TypeCheckResult r -> [TypeCheckError]
getTCRE (TypeCheckResult notes _) = notes
getTCRE (TypeCheckResE notes) = notes

instance Functor TypeCheckResult where
  fmap f (TypeCheckResult notes r) = TypeCheckResult notes (f r)
  fmap _ (TypeCheckResE notes) = TypeCheckResE notes

instance Applicative TypeCheckResult where
  pure = TypeCheckResult []
  (TypeCheckResult notesA f) <*> (TypeCheckResult notesB b) = TypeCheckResult (notesA ++ notesB) (f b)
  resA <*> resB = TypeCheckResE (getTCRE resA ++ getTCRE resB)

instance Monad TypeCheckResult where
  return = pure
  (TypeCheckResult notesA a) >>= f = case f a of
    (TypeCheckResult notesB b) -> TypeCheckResult (notesA ++ notesB) b
    (TypeCheckResE notesB) -> TypeCheckResE (notesA ++ notesB)
  (TypeCheckResE notes) >>= _ = TypeCheckResE notes


type PreMeta = PreTyped
type PExpr = IExpr PreMeta
type PCompAnnot = CompAnnot PExpr
type PGuard = Guard PExpr
type PArrow = Arrow PExpr PreMeta
type PObjArg = ObjArg PreMeta
type PObject = Object PreMeta
type PPrgm = Prgm PExpr PreMeta
type PReplRes = ReplRes PreMeta

type ShowMeta = Scheme
type SExpr = IExpr ShowMeta
type SCompAnnot = CompAnnot SExpr
type SGuard = Guard SExpr
type SArrow = Arrow SExpr ShowMeta
type SObjArg = ObjArg ShowMeta
type SObject = Object ShowMeta
type SPrgm = Prgm SExpr ShowMeta
type SReplRes = ReplRes ShowMeta

data VarMeta = VarMeta Pnt PreTyped (Maybe VObject)
  deriving (Eq, Ord, Show, Generic, Hashable, ToJSON)
type VExpr = IExpr VarMeta
type VCompAnnot = CompAnnot VExpr
type VGuard = Guard VExpr
type VArgMetaMap = ArgMetaMap VarMeta
type VArrow = Arrow VExpr VarMeta
type VObjArg = ObjArg VarMeta
type VObject = Object VarMeta
type VObjectMap = [(VObject, [VArrow])]
type VPrgm = (VObjectMap, ClassMap)
type VReplRes = ReplRes VarMeta

type TypedMeta = Typed
type TExpr = Expr TypedMeta
type TCompAnnot = CompAnnot TExpr
type TGuard = Guard TExpr
type TArrow = Arrow TExpr TypedMeta
type TObjArg = ObjArg TypedMeta
type TObject = Object TypedMeta
type TPrgm = Prgm TExpr TypedMeta
type TReplRes = ReplRes TypedMeta

-- implicit graph
type TypeGraphVal = (VObject, VArrow) -- (match object type, if matching then can implicit to type in arrow)
type TypeGraph = H.HashMap TypeName [TypeGraphVal] -- H.HashMap (Root tuple name for filtering) [vals]

instance Meta VarMeta where
  getMetaType (VarMeta _ p _) = getMetaType p

instance Show TypeCheckError where
  show (GenTypeCheckError s) = s
  show (AbandonCon c) = printf "Abandon %s" (show c)
  show (TupleMismatch baseM baseExpr m args) = printf "Tuple Apply Mismatch:\n\t(%s %s)(%s) ≠ %s\n\t" (show baseM) (show baseExpr) args' (show m)
    where
      showArg (argName, argVal) = printf "%s = %s" argName (show argVal)
      args' = intercalate ", " $ map showArg $ H.toList args
  show (TCWithMatchingConstraints constraints er) = printf "%s\n\tConstraints: %s" (show er) (show constraints)

instance Show SType where
  show (SType upper lower desc) = concat [show upper, " ⊇ ", desc, " ⊇ ", show lower]
  show (SVar varName p) = printf "SVar %s %s" (show p) (show varName)

instance Show SConstraint where
  show (SEqualsKnown s t) = printf "%s == %s" (show s) (show t)
  show (SEqPoints s1 s2) = printf "%s == %s" (show s1) (show s2)
  show (SBoundedByKnown s t) = printf "%s ⊆ %s" (show s) (show t)
  show (SBoundedByObjs b s) = printf "%s %s" (show b) (show s)
  show (SArrowTo f t) = printf "%s -> %s" (show t) (show f)
  show (SPropEq (s1, n) s2) = printf "(%s).%s == %s"  (show s1) n (show s2)
  show (SVarEq (s1, n) s2) = printf "(%s).%s == %s"  (show s1) n (show s2)
  show (SAddArg (base, arg) res) = printf "(%s)(%s) == %s" (show base) arg (show res)
  show (SAddInferArg base res) = printf "(%s)(?) == %s" (show base) (show res)
  show (SPowersetTo s t) = printf "𝒫(%s) ⊇ %s" (show s) (show t)
  show (SUnionOf s _) = printf "SUnionOf for %s" (show s)

instance Show r => Show (TypeCheckResult r) where
  show (TypeCheckResult [] r) = show r
  show (TypeCheckResult notes r) = concat ["TCRes [", show notes, "] (", show r, ")"]
  show (TypeCheckResE notes) = concat ["TCErr [", show notes, "]"]

getPnt :: VarMeta -> Pnt
getPnt (VarMeta p _ _) = p

fLookup :: FEnv -> String -> TypeCheckResult VarMeta
fLookup FEnv{feDefMap} k = case H.lookup k feDefMap of
  Just v  -> return v
  Nothing -> TypeCheckResE [GenTypeCheckError $ "Failed to lookup " ++ k]

addConstraints :: FEnv -> [Constraint] -> FEnv
addConstraints env@FEnv{feCons} newCons = env {feCons = (newCons ++ feCons)}

fInsert :: FEnv -> String -> VarMeta -> FEnv
fInsert env@FEnv{feDefMap} k v = env{feDefMap = H.insert k v feDefMap}

fAddTypeGraph :: FEnv -> TypeName -> TypeGraphVal -> FEnv
fAddTypeGraph env@FEnv{feTypeGraph} k v = env {feTypeGraph = H.insertWith (++) k [v] feTypeGraph}

tryIntersectTypes :: FEnv -> Type -> Type -> String -> TypeCheckResult Type
tryIntersectTypes FEnv{feClassMap} a b desc = let c = intersectTypes feClassMap a b
                                                            in if isBottomType c
                                                                  then TypeCheckResE [GenTypeCheckError $ "Failed to intersect(" ++ desc ++ "): " ++ show a ++ " --- " ++ show b]
                                                                  else return c

-- Point operations

descriptor :: FEnv -> VarMeta -> Scheme
descriptor FEnv{fePnts} p = fePnts IM.! (getPnt p)

equivalent :: FEnv -> VarMeta -> VarMeta -> Bool
equivalent FEnv{fePnts} m1 m2 = (fePnts IM.! getPnt m1) == (fePnts IM.! getPnt m2)

fresh :: FEnv -> Scheme -> (Pnt, FEnv)
fresh env@FEnv{fePnts} scheme = (pnt', env{fePnts = pnts'})
  where
    pnt' = IM.size fePnts
    pnts' = IM.insert pnt' scheme fePnts

setDescriptor :: FEnv -> VarMeta -> Scheme -> FEnv
setDescriptor env@FEnv{fePnts, feTrace} m scheme' = env{fePnts = pnts', feTrace = feTrace'}
  where
    p = getPnt m
    scheme = fePnts IM.! p
    schemeChanged = scheme /= scheme'
    pnts' = IM.insert p scheme' fePnts
    feTrace' = if schemeChanged
      then case feTrace of
             ((curConstraint, curChanged):curEpoch):prevEpochs -> ((curConstraint, (p, scheme'):curChanged):curEpoch):prevEpochs
             _ -> error "no epochs in feTrace"
      else feTrace


-- trace constrain
type TraceConstrain = [[(Constraint, [(Pnt, Scheme)])]]

nextConstrainEpoch :: FEnv -> FEnv
nextConstrainEpoch env@FEnv{feTrace} = case feTrace of
  [] -> env
  prevEpochs -> env{feTrace = ([]:prevEpochs)}

startConstraint :: Constraint -> FEnv -> FEnv
startConstraint c env@FEnv{feTrace = curEpoch:prevEpochs} = env{feTrace = ((c, []):curEpoch):prevEpochs}
startConstraint _ _ = error "bad input to startConstraint"

substituteVarsWithVarEnv :: TypeVarEnv -> Type -> Type
substituteVarsWithVarEnv venv (SumType partials) = SumType $ joinPartialLeafs $ map substitutePartial $ splitPartialLeafs partials
  where substitutePartial (partialName, partialVars, partialProps, partialArgs) = (partialName, partialVars, fmap (substituteVarsWithVarEnv venv') partialProps, fmap (substituteVarsWithVarEnv venv') partialArgs)
          where venv' = H.union venv partialVars
substituteVarsWithVarEnv venv (TypeVar (TVVar v)) = case H.lookup v venv of
  Just v' -> v'
  Nothing -> error $ printf "Could not substitute unknown type var %s" v
substituteVarsWithVarEnv _ t = t

substituteVars :: Type -> Type
substituteVars = substituteVarsWithVarEnv H.empty
