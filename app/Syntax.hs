--------------------------------------------------------------------
-- |
-- Module    :  Syntax
-- Copyright :  (c) Stephen Diehl 2013
-- License   :  MIT
-- Maintainer:  stephen.m.diehl@gmail.com
-- Stability :  experimental
-- Portability: non-portable
--
--------------------------------------------------------------------

module Syntax where

type Name = String

data Import = Import String
  deriving (Eq, Ord, Show)

data Export = Export String
  deriving (Eq, Ord, Show)

data Constant
  = Int Integer
  | Float Double
  deriving (Eq, Ord, Show)

data Expr
  = CExpr Constant
  | Var String
  | UnaryOp Name Expr
  | BinaryOp Name Expr Expr
  | Call Name [Expr]
  deriving (Eq, Ord, Show)

data DeclLHS
  = DeclVal Name
  | DeclFun Name [Name]
  deriving (Eq, Ord, Show)

data Decl = Decl DeclLHS [Decl] Expr
  deriving (Eq, Ord, Show)

data Prgm = Prgm [Import] [Export] [Decl]
