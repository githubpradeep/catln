--------------------------------------------------------------------
-- |
-- Module    :  Desugarf
-- Copyright :  (c) Zach Kimberg 2019
-- License   :  MIT
-- Maintainer:  zachary@kimberg.com
-- Stability :  experimental
-- Portability: non-portable
--
--------------------------------------------------------------------

module Desugarf where


import           Data.Hashable
import qualified Data.HashMap.Strict as H
import qualified Data.HashSet        as S
import           Data.Bifunctor                 ( first )
import           Data.List
import           Data.Maybe
import           Text.Printf

import           Syntax.Types
import           Syntax.Prgm
import           Syntax
import           CRes
import           Parser.Syntax
import           Desugarf.Passes

splitDeclSubStatements :: [PDeclSubStatement] -> ([PDecl], [PCompAnnot])
splitDeclSubStatements = aux ([], [])
  where
    aux (decls, annots) [] = (decls, annots)
    aux (decls, annots) (RawDeclSubStatementDecl decl : subSt) = aux (decl:decls, annots) subSt
    aux (decls, annots) (RawDeclSubStatementAnnot annot : subSt) = aux (decls, annot:annots) subSt

scopeSubDeclFunNamesInS :: TypeName -> S.HashSet TypeName -> TypeName -> TypeName
scopeSubDeclFunNamesInS prefix replaceNames name = name'
  where
    addPrefix n = prefix ++ "." ++ n
    name' = if S.member name replaceNames then addPrefix name else name

scopeSubDeclFunNamesInPartialName :: TypeName -> S.HashSet TypeName -> PartialName -> PartialName
scopeSubDeclFunNamesInPartialName prefix replaceNames (PTypeName name) = PTypeName $ scopeSubDeclFunNamesInS prefix replaceNames name
scopeSubDeclFunNamesInPartialName prefix replaceNames (PClassName name) = PClassName $ scopeSubDeclFunNamesInS prefix replaceNames name

scopeSubDeclFunNamesInExpr :: TypeName -> S.HashSet TypeName -> PSExpr -> PSExpr
scopeSubDeclFunNamesInExpr _ _ e@PSCExpr{} = e
scopeSubDeclFunNamesInExpr prefix replaceNames (PSValue m name) = PSValue m $ scopeSubDeclFunNamesInS prefix replaceNames name
scopeSubDeclFunNamesInExpr prefix replaceNames (PSTupleApply m (bm, bExpr) argName argVal) = PSTupleApply m (bm, bExpr') argName argVal'
  where
    bExpr' = scopeSubDeclFunNamesInExpr prefix replaceNames bExpr
    argVal' = scopeSubDeclFunNamesInExpr prefix replaceNames argVal

scopeSubDeclFunNamesInMeta :: TypeName -> S.HashSet TypeName -> ParseMeta -> ParseMeta
scopeSubDeclFunNamesInMeta prefix replaceNames (PreTyped (SumType partials)) = PreTyped $ SumType partials'
  where
    scopeS = scopeSubDeclFunNamesInPartialName prefix replaceNames
    partials' = H.fromList $ map (first scopeS) $ H.toList partials
scopeSubDeclFunNamesInMeta _ _ m@(PreTyped TopType) = m
scopeSubDeclFunNamesInMeta _ _ m@(PreTyped TypeVar{}) = m

-- Renames sub functions by applying the parent names as a prefix to avoid name collisions
scopeSubDeclFunNames :: TypeName -> [PSemiDecl] -> Maybe PSExpr -> [PSCompAnnot] -> ParseMeta -> ParseMeta -> ([PSemiDecl], Maybe PSExpr, [PSCompAnnot], ParseMeta, ParseMeta)
scopeSubDeclFunNames prefix decls maybeExpr annots objM arrM = (decls', expr', annots', objM', arrM')
  where
    declNames = S.fromList $ map (\(PSemiDecl (DeclLHS _ (Pattern (Object _ _ name _ _) _)) _ _) -> name) decls
    addPrefix n = prefix ++ "." ++ n
    scopeM = scopeSubDeclFunNamesInMeta prefix declNames
    objM' = scopeM objM
    arrM' = scopeM arrM
    decls' = map (\(PSemiDecl (DeclLHS aM (Pattern (Object oM basis name vars args) guard)) annot subExpr) -> PSemiDecl (DeclLHS (scopeM aM) (Pattern (Object (scopeM oM) basis (addPrefix name) vars args) guard)) annot (fmap (scopeSubDeclFunNamesInExpr prefix declNames) subExpr)) decls
    expr' = fmap (scopeSubDeclFunNamesInExpr prefix declNames) maybeExpr
    annots' = map (\(CompAnnot n ca) -> CompAnnot n (fmap (scopeSubDeclFunNamesInExpr prefix declNames) ca)) annots

currySubFunctionSignature :: H.HashMap ArgName PObjArg -> PSemiDecl -> PSemiDecl
currySubFunctionSignature parentArgs (PSemiDecl (DeclLHS arrM (Pattern (Object objM basis name vars args) guard)) annot expr) = PSemiDecl (DeclLHS arrM (Pattern (Object objM basis name vars args') guard)) annot expr
  where args' = H.union args parentArgs


currySubFunctionsUpdateExpr :: S.HashSet TypeName -> H.HashMap ArgName PObjArg -> PSExpr -> PSExpr
currySubFunctionsUpdateExpr _ _ c@PSCExpr{} = c
currySubFunctionsUpdateExpr _ parentArgs v@PSValue{} | H.null parentArgs = v
currySubFunctionsUpdateExpr toUpdate parentArgs v@(PSValue _ vn) = if S.member vn toUpdate
  then foldr (\(parentArgName, (parentArgM, _)) e -> PSTupleApply emptyMeta (emptyMeta, e) (Just parentArgName) (PSValue parentArgM parentArgName)) v $ H.toList parentArgs
  else v
currySubFunctionsUpdateExpr toUpdate parentArgs (PSTupleApply tm (tbm, tbe) tArgName tArgVal) = PSTupleApply tm (tbm, tbe') tArgName tArgVal'
  where
    tbe' = currySubFunctionsUpdateExpr toUpdate parentArgs tbe
    tArgVal' = currySubFunctionsUpdateExpr toUpdate parentArgs tArgVal

currySubFunctions :: H.HashMap ArgName PObjArg -> [PSemiDecl] -> Maybe PSExpr -> [PSCompAnnot] -> ([PSemiDecl], Maybe PSExpr, [PSCompAnnot])
currySubFunctions parentArgs decls expr annots = (decls', expr', annots')
  where
    toUpdate = S.fromList $ map (\(PSemiDecl (DeclLHS _ (Pattern (Object _ _ declName _ _) _)) _ _) -> declName) decls
    decls2 = map (currySubFunctionSignature parentArgs) decls
    expr' = fmap (currySubFunctionsUpdateExpr toUpdate parentArgs) expr
    decls' = map (\(PSemiDecl lhs an e) -> PSemiDecl lhs an (fmap (currySubFunctionsUpdateExpr toUpdate parentArgs) e)) decls2
    annots' = map (\(CompAnnot n ca) -> CompAnnot n (fmap (currySubFunctionsUpdateExpr toUpdate parentArgs) ca)) annots

removeSubDeclarations :: PDecl -> [PSemiDecl]
removeSubDeclarations (RawDecl (DeclLHS arrM (Pattern (Object objM basis declName vars args) guard1)) subStatements expr1) = decl':subDecls5
  where
    (subDecls, annots1) = splitDeclSubStatements subStatements
    subDecls2 = concatMap removeSubDeclarations subDecls
    (subDecls21, expr2) = traverse semiDesExpr expr1
    (subDecls22, annots2) = traverse semiDesAnnot annots1
    (subDecls23, guard2) = semiDesGuard guard1
    subDecls3 = concat [subDecls2, subDecls21, subDecls22, subDecls23]
    (subDecls4, expr3, annots3, objM', arrM') = scopeSubDeclFunNames declName subDecls3 expr2 annots2 objM arrM
    (subDecls5, expr4, annots4) = currySubFunctions args subDecls4 expr3 annots3
    decl' = PSemiDecl (DeclLHS arrM' (Pattern (Object objM' basis declName vars args) guard2)) annots4 expr4

desExpr :: PArgMetaMap -> PSExpr -> DesExpr
desExpr _ (PSCExpr m c) = ICExpr m c
desExpr arrArgs (PSValue m n) = if H.member n arrArgs
  then IArg m n
  else IValue m n
desExpr arrArgs (PSTupleApply m (bm, be) argName argVal) = ITupleApply m (bm, desExpr arrArgs be) argName (desExpr arrArgs argVal)

desGuard :: PArgMetaMap -> PSGuard -> DesGuard
desGuard arrArgs = fmap (desExpr arrArgs)

desAnnot :: PArgMetaMap -> PSCompAnnot -> DesCompAnnot
desAnnot arrArgs (CompAnnot name args) = CompAnnot name (fmap (desExpr arrArgs) args)

semiDesExpr :: PExpr -> ([PSemiDecl], PSExpr)
semiDesExpr (RawCExpr m c) = ([], PSCExpr m c)
semiDesExpr (RawValue m n) = ([], PSValue m n)
semiDesExpr (RawTupleApply m'' (bm, be) args) = (\(a, _, PSTupleApply _ (bm'', be'') argName'' argVal'') -> (a, PSTupleApply m'' (bm'', be'') argName'' argVal'')) $ foldl aux (subBe, bm, be') args
  where
    (subBe, be') = semiDesExpr be
    aux (sub, m, e) (RawTupleArgNamed argName argVal) = (subArgVal ++ sub, emptyMeta, PSTupleApply emptyMeta (m, e) (Just argName) argVal')
      where (subArgVal, argVal') = semiDesExpr argVal
    aux (sub, m, e) (RawTupleArgInfer argVal) = (subArgVal ++ sub, emptyMeta, PSTupleApply emptyMeta (m, e) Nothing argVal')
      where (subArgVal, argVal') = semiDesExpr argVal
semiDesExpr (RawMethods base methods) = semiDesExpr $ foldl addMethod base methods
  where
    addMethod b method@RawValue{} = RawTupleApply emptyMeta (emptyMeta, method) [RawTupleArgNamed "this" b]
    addMethod b (RawTupleApply m methodVal methodArgs) = RawTupleApply m methodVal (RawTupleArgNamed "this" b : methodArgs)
    addMethod _ _ = error "Unknown semiDesExpr method"
semiDesExpr r@(RawIfThenElse m i t e) = (concat [subI, subT, subE, [elseDecl, ifDecl]], expr')
  where
    condName = "\\" ++ take 6 (printf "%08x" (hash r))
    (subI, i') = semiDesExpr i
    (subT, t') = semiDesExpr t
    (subE, e') = semiDesExpr e
    ifDecl = PSemiDecl (DeclLHS emptyMeta (Pattern (Object emptyMeta FunctionObj condName H.empty H.empty) (IfGuard i'))) [] (Just t')
    elseDecl = PSemiDecl (DeclLHS emptyMeta (Pattern (Object emptyMeta FunctionObj condName H.empty H.empty) ElseGuard)) [] (Just e')
    expr' = PSValue m condName
semiDesExpr r@(RawMatch m e matchItems) = (subE ++ subMatchItems, expr')
  where
    condName = "\\" ++ take 6 (printf "%08x" (hash r))
    argName = condName ++ "-arg"
    (subE, e') = semiDesExpr e
    expr' = PSTupleApply m (emptyMeta, PSValue emptyMeta condName) (Just argName) e'
    subMatchItems = concatMap semiDesMatchItem $ H.toList matchItems
    semiDesMatchItem (Pattern patt pattGuard, matchExpr) = concat [[matchItemExpr'], subPattGuard, subMatchExpr]
      where
        (subPattGuard, pattGuard') = semiDesGuard pattGuard
        (subMatchExpr, matchExpr') = semiDesExpr matchExpr
        matchArg = H.singleton argName (emptyMeta, Just patt)
        matchItemExpr' = PSemiDecl (DeclLHS emptyMeta (Pattern (Object emptyMeta FunctionObj condName H.empty matchArg) pattGuard')) [] (Just matchExpr')
semiDesExpr (RawCase _ _ ((Pattern _ ElseGuard, _):_)) = error "Can't use elseguard in match expr"
semiDesExpr (RawCase _ _ []) = error "Empty case"
semiDesExpr (RawCase _ _ [(_, matchExpr)]) = semiDesExpr matchExpr
semiDesExpr r@(RawCase m e ((Pattern firstObj@(Object fm _ _ _ _) firstGuard, firstExpr):restCases)) = (concat [[firstDecl, restDecl], subFG, subFE, subRE, subE], expr')
  where
    condName = "\\" ++ take 6 (printf "%08x" (hash r))
    argName = condName ++ "-arg"
    declObj = Object emptyMeta FunctionObj condName H.empty (H.singleton argName (fm, Just firstObj))
    firstDecl = PSemiDecl (DeclLHS m (Pattern declObj firstGuard')) [] (Just firstExpr')
    (subFG, firstGuard') = semiDesGuard firstGuard
    (subFE, firstExpr') = semiDesExpr firstExpr
    restDecl = PSemiDecl (DeclLHS m (Pattern declObj ElseGuard)) [] (Just restExpr')
    (subRE, restExpr') = semiDesExpr (RawCase m e restCases)
    (subE, e') = semiDesExpr e
    expr' = PSTupleApply m (emptyMeta, PSValue emptyMeta condName) (Just argName) e'


semiDesGuard :: PGuard -> ([PSemiDecl], PSGuard)
semiDesGuard (IfGuard e) = (subE, IfGuard e')
  where (subE, e') = semiDesExpr e
semiDesGuard ElseGuard = ([], ElseGuard)
semiDesGuard NoGuard = ([], NoGuard)

semiDesAnnot :: PCompAnnot -> ([PSemiDecl], PSCompAnnot)
semiDesAnnot (CompAnnot name args) = (subArgs, CompAnnot name args')
  where (subArgs, args') = traverse semiDesExpr args

declToObjArrow :: PSemiDecl -> (DesObject, [DesArrow])
declToObjArrow (PSemiDecl (DeclLHS arrM (Pattern object guard)) annots expr) = (object, [arrow])
  where
    argMetaMap = formArgMetaMap object
    arrow = Arrow arrM (map (desAnnot argMetaMap) annots) (desGuard argMetaMap guard) (fmap (desExpr argMetaMap) expr)

desDecl :: PDecl -> DesObjectMap
desDecl decl = H.fromListWith (++) $ map declToObjArrow $ removeSubDeclarations decl

desDecls :: [PDecl] -> DesObjectMap
desDecls decls = unionsWith (++) $ map desDecl decls

typeDefMetaToObj :: H.HashMap TypeVarName Type -> ParseMeta -> Maybe PObject
typeDefMetaToObj _ (PreTyped TypeVar{}) = Nothing
typeDefMetaToObj varReplaceMap m@(PreTyped (SumType partials)) = case splitPartialLeafs partials of
  [(PTypeName partialName, partialVars, _, partialArgs)] -> Just $ Object m TypeObj partialName (fmap fixVar partialVars) (fmap ((,Nothing) . PreTyped) partialArgs)
    where
      fixVar v@(TypeVar (TVVar t)) = PreTyped $ fromMaybe v $ H.lookup t varReplaceMap
      fixVar v = PreTyped v
  _ -> error "Invalid call to typeDefMetaToObj with SumType"
typeDefMetaToObj _ _ = error "Invalid call to typeDefMetaToObj"

desMultiTypeDefs :: [PMultiTypeDef] -> (DesObjectMap, ClassMap)
desMultiTypeDefs = foldr addTypeDef (H.empty, (H.empty, H.empty))
  where
    addTypeDef (MultiTypeDef className classVars dataMetas) (objMap, (typeToClass, classToType)) = (objMap', (typeToClass', classToType'))
      where
        objMap' = mergeObjMaps objMap $ H.fromList $ map (,[]) objs
        objNames = map (\(Object _ _ name _ _) -> name) objs
        dataTypes = map (\(PreTyped tp) -> tp) dataMetas
        objs = mapMaybe (typeDefMetaToObj classVars) dataMetas
        unionSealType (sealed, cv, a) (_, _, b) = (sealed, cv, a ++ b)
        classToType' = H.insertWith unionSealType className (True, classVars, dataTypes) classToType
        newTypeToClass = H.fromList $ map (,S.singleton className) objNames
        typeToClass' = H.unionWith S.union typeToClass newTypeToClass

desTypeDefs :: [PTypeDef] -> DesObjectMap
desTypeDefs = foldr addTypeDef H.empty
  where addTypeDef (TypeDef tp) = case typeDefMetaToObj H.empty tp of
          Just obj -> H.insert obj []
          Nothing -> error "Type def could not be converted into meta"

desClassDefs :: Sealed -> [RawClassDef] -> ClassMap
desClassDefs sealed = foldr addDef empty
  where
    empty = (H.empty, H.empty)
    addDef (typeName, className) (typeToClass, classToType) = (H.insertWith S.union typeName (S.singleton className) typeToClass, H.insertWith addClass className (sealed, H.empty, [singletonType (PTypeName typeName, H.empty, H.empty, H.empty)]) classToType)
    addClass (cSealed, cVars, set1) (_, _, set2) = (cSealed, cVars, set1 ++ set2)

mergeObjMaps :: DesObjectMap -> DesObjectMap -> DesObjectMap
mergeObjMaps = H.unionWith (++)

mergeClassMaps :: ClassMap -> ClassMap -> ClassMap
mergeClassMaps classMap@(toClassA, toTypeA) (toClassB, toTypeB) = (H.unionWith S.union toClassA toClassB, H.unionWith mergeClasses toTypeA toTypeB)
  where mergeClasses (sealedA, classVarsA, setA) (sealedB, classVarsB, setB) = if sealedA == sealedB
          then (sealedA, H.unionWith (unionType classMap) classVarsA classVarsB, setA ++ setB)
          else error "Added to sealed class definition"

desStatements :: [PStatement] -> DesPrgm
desStatements statements = (objMap, classMap)
  where
    splitStatements statement = case statement of
          RawDeclStatement decl -> ([decl], [], [], [])
          MultiTypeDefStatement multiTypedef -> ([], [multiTypedef], [], [])
          TypeDefStatement typedef -> ([], [], [typedef], [])
          RawClassDefStatement classdef -> ([], [], [], [classdef])
          RawComment _ -> ([], [], [], [])
    (decls, multiTypes, types, classes) = (\(a, b, c, d) -> (concat a, concat b, concat c, concat d)) $ unzip4 $ map splitStatements statements
    declObjMap = desDecls decls
    typeObjMap = desTypeDefs types
    (multiTypeObjMap, sealedClasses) = desMultiTypeDefs multiTypes
    unsealedClasses = desClassDefs False classes
    objMap = foldr mergeObjMaps H.empty [declObjMap, multiTypeObjMap, typeObjMap]
    classMap = mergeClassMaps sealedClasses unsealedClasses

finalPasses :: DesPrgm -> DesPrgm
finalPasses = typeNameToClass

desPrgm :: PPrgm -> CRes DesPrgm
desPrgm (_, statements) = return $ finalPasses $ desStatements statements

desFiles :: PPrgms -> CRes DesPrgm
desFiles rawPrgms = desPrgm $ foldr (joinPrgms . snd) emptyPrgm rawPrgms
  where
    emptyPrgm = ([], [])
    joinPrgms (aImports, aStatements) (bImports, bStatements) = (aImports ++ bImports, aStatements ++ bStatements)
