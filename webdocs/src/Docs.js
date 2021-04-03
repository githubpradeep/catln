import React from 'react';

import Grid from '@material-ui/core/Grid';
import TreeView from '@material-ui/lab/TreeView';
import ExpandMoreIcon from '@material-ui/icons/ExpandMore';
import ChevronRightIcon from '@material-ui/icons/ChevronRight';
import TreeItem from '@material-ui/lab/TreeItem';
import ReactMarkdown from 'react-markdown';
import {
  Switch,
  Route,
  Redirect,
  Link,
  useParams,
  useRouteMatch
} from 'react-router-dom';

import {useApi, posKey, Loading, Obj, Guard, Type, Val, tagJoin} from './Common';

const useStyles = {
  indented: {
    marginLeft: '4em'
  }
};

function Docs() {
  let apiResult = useApi("/pages");

  return (
    <Loading status={apiResult}>
      <Main data={apiResult.data} />
    </Loading>
  );
}

function Main(props) {
  let [pages, annots] = props.data;

  const pagesMap = {};
  pages.forEach(page => {
    const [pageData, pageName, pageDeps] = page;
    pagesMap[pageName] = [pageData, pageDeps];
  });

  var annotsMap = {};
  annots.forEach(annot => {
    let pos = annot[0].contents[0][1];
    let val = annot[1];
    annotsMap[posKey(pos)] = val;
  });

  let { path } = useRouteMatch();

  const startingPage = encodeURIComponent(pages[pages.length - 1][1]);

  return (
    <Switch>
      <Route exact path={path}>
        <Redirect to={`${path}/${startingPage}`} />
      </Route>
      <Route path={`${path}/:curPage`}>
        <Grid container spacing={2} justify="center">
          <Grid item xs={2}>
            <TreeView
              defaultCollapseIcon={<ExpandMoreIcon />}
              defaultExpandIcon={<ChevronRightIcon />}
            >
              <TableOfContentsNodes pageTree={buildPageTree(pagesMap)} prevTree="" path={path} />
            </TreeView>
          </Grid>
          <Grid item xs={8}>
            <MainStatements pagesMap={pagesMap} annotsMap={annotsMap}/>
          </Grid>
        </Grid>
      </Route>
    </Switch>
  );
}

function buildPageTree(pagesMap) {
  const pageNames = Object.keys(pagesMap);
  const tree = {};
  pageNames.forEach(pageName => {
    const pageDirs = pageName.split("/");
    const pageFile = pageDirs.splice(-1, 1);
    let curTree = tree;
    pageDirs.forEach(pageDir => {
      if(!(pageDir in curTree)) {
        curTree[pageDir] = {};
      }
      curTree = curTree[pageDir];
    });
    curTree[pageFile] = 1;
  });
  return tree;
}

function TableOfContentsNodes(props) {
  const {pageTree, prevTree, path} = props;

  let trees = Object.keys(pageTree);
  if(trees.includes("main.ct")) {
    trees.splice(trees.indexOf("main.ct"), 1);
    trees.unshift("main.ct");
  }

  return trees.map(tree => {

    let newPrevTree = [prevTree, tree].join("/");
    if(prevTree === "") newPrevTree = tree;

    if(isNaN(pageTree[tree])) {
      // Directory

      return (
        <TreeItem key={tree} nodeId={newPrevTree} label={tree} >
          <TableOfContentsNodes key={tree} pageTree={pageTree[tree]} prevTree={newPrevTree} path={path} />
        </TreeItem>
      );
    } else {
      // File

      let label = <Link to={`${path}/${encodeURIComponent(newPrevTree)}`} >{tree}</Link>;
      return (
        <TreeItem key={tree} nodeId={newPrevTree} label={label} />
      );
    }

  });
}

function MainStatements(props) {
  const {pagesMap, annotsMap} = props;
  const { curPage } = useParams();

  const page = pagesMap[decodeURIComponent(curPage)];
  const statements = page[0][1];

  return <Statements statements={statements} annotsMap={annotsMap} />;
}

function Statements(props) {
  return props.statements.map((statement, index) => <Statement key={index} statement={statement} annotsMap={props.annotsMap}/>);
}

function Statement(props) {
  let {statement, annotsMap} = props;
  switch(statement.tag) {
  case "RawDeclStatement":
    return <Decl contents={statement.contents} />;
  case "MultiTypeDefStatement":
    let [className, classVars, classDatas] = statement.contents;

    let showClassVars;
    if(Object.keys(classVars).length > 0) {
      showClassVars = (
        <span>
          &lt;
          {tagJoin(Object.keys(classVars).map(v => <span key={v}><Type data={classVars[v]}/> v</span>), ", ")}
          &gt;
        </span>
      );
    }

    let showClassDatas = tagJoin(classDatas.map((d, dIndex) => <span key={dIndex}><Type data={d[0]}/></span>), " | ");

    return (<div>class {className}{showClassVars} = {showClassDatas}</div>);
  case "TypeDefStatement":
    return (<div>data <Type data={statement.contents[0]}/></div>);
  case "RawClassDefStatement":
    let [[instanceType, instanceVars], instanceClass] = statement.contents;

    let showInstanceVars;
    if(Object.keys(instanceVars).length > 0) {
      showInstanceVars = (
        <span>
          &lt;
          {tagJoin(Object.keys(instanceVars).map(v => <span key={v}><Type data={instanceVars[v]}/> v</span>), ", ")}
          &gt;
        </span>
      );
    }

    return (<div>instance {instanceType}{showInstanceVars} of {instanceClass}</div>);
  case "RawClassDeclStatement":
    let [classDeclName, classDeclVars] = statement.contents;

    let showClassDeclVars;
    if(Object.keys(classDeclVars).length > 0) {
      showClassDeclVars = (
        <span>
          &lt;
          {tagJoin(Object.keys(classDeclVars).map(v => <span key={v}><Type data={classDeclVars[v]}/> v</span>), ", ")}
          &gt;
        </span>
      );
    }


    return (<div>class {classDeclName}{showClassDeclVars}</div>);
  case "RawGlobalAnnot":
    let pos = statement.contents.contents[0][1];
    let val = annotsMap[posKey(pos)];

    let showAnnotExpr = <Expr expr={statement.contents} />;
    if(val.name === "#print") {
      return (
        <div>
          {showAnnotExpr}
          <br />
          <Val data={val.args.p} />
        </div>
      );
    } else {
      return showAnnotExpr;
    }
  case "RawComment":
    return (<ReactMarkdown children={statement.contents} />);
  default:
    console.error("Unknown renderStatement", statement);
    return "";
  }
}

function Decl(props) {
  let [lhs, subStatements, maybeExpr] = props.contents;
  let [, [obj, guard]] = lhs;

  let showExpr;
  if(maybeExpr) {
    showExpr = (<span> = <Expr expr={maybeExpr}/></span>);
  }

  return (
    <div>
      <Obj obj={obj} Meta={RawMeta}/><Guard guard={guard} Expr={Expr}/>{showExpr}
      <div style={useStyles.indented}>
        {subStatements.map((subStatement, index) => <DeclSubStatement key={index} subStatement={subStatement} />)}
      </div>
    </div>
  );
}

function DeclSubStatement(props) {
  const {subStatement} = props;

  switch(subStatement.tag) {
  case "RawDeclSubStatementDecl":
    return <Decl contents={subStatement.contents} />;
  case "RawDeclSubStatementAnnot":
    return <div><Expr expr={subStatement.contents} /></div>;
  default:
    console.error("Unknown DeclSubStatement", subStatement);
    return "";
  }
}

function Expr(props) {
  let {expr} = props;
  switch(expr.tag) {
  case "RawCExpr":
    return "" + expr.contents[1].contents;
  case "RawValue":
    return "" + expr.contents[1];
  case "RawTupleApply":
    const [, [,base], args] = expr.contents;

    let showArgs = tagJoin(args.map((arg, argIndex) => {
      switch(arg.tag) {
      case "RawTupleArgNamed":
        return (<span key={argIndex}>{arg.contents[0]} = <Expr expr={arg.contents[1]}/></span>);
      case "RawTupleArgInfer":
        return <Expr key={argIndex} expr={arg.contents}/>;
      default:
        console.error("Unknown renderExpr tupleApply arg type");
        return <span key={argIndex}></span>;
      }
    }), ", ");

    return (<span><Expr expr={base}/>({showArgs})</span>);
  case "RawParen":
    return <span>(<Expr expr={expr.contents}/>)</span>;
  case "RawMethods":
    let [mBase, methods] = expr.contents;
    let showMethods = methods.map((method, methodIndex) => <span key={methodIndex}>.<Expr expr={method}/></span>);
    return (<span><Expr expr={mBase}/>{showMethods}</span>);
  case "RawIfThenElse":
    let [, ifExpr, thenExpr, elseExpr] = expr.contents;
    return (<span>if <Expr expr={ifExpr}/> then <Expr expr={thenExpr}/> else <Expr expr={elseExpr}/></span>);
  case "RawMatch":
    let [, matchExpr, matchPatterns] = expr.contents;
    let showMPatterns = tagJoin(matchPatterns.map((pattern, patternIndex) => {
      let [obj, guard] = pattern;
      return (<span key={patternIndex}><Obj obj={obj} Meta={RawMeta}/><Guard guard={guard} Expr={Expr}/></span>);
    }), "");
    return (<span>match <Expr expr={matchExpr}/> of <div style={useStyles.indented}>{showMPatterns}</div></span>);
  case "RawCase":
    let [, caseExpr, casePatterns] = expr.contents;
    let showCPatterns = tagJoin(casePatterns.map((pattern, patternIndex) => {
      let [obj, guard] = pattern;
      return (<span key={patternIndex}><Obj obj={obj} Meta={RawMeta}/><Guard guard={guard} Expr={Expr}/></span>);
    }), "");
    return (<span>case <Expr expr={caseExpr}/> of <div style={useStyles.indented}>{showCPatterns}</div></span>);
  default:
    console.error("Unknown renderExpr", expr);
    return "";
  }
}

function RawMeta(props) {
  let [tp, ] = props.data;
  return <Type data={tp} />;
}


export default Docs;
