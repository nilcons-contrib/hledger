{-# LANGUAGE TypeFamilies #-}
{-

Define the web application's foundation, in the usual Yesod style.
See a default Yesod app's comments for more details of each part.

-}
module Foundation where

import Prelude
import Control.Applicative ((<$>))
import Data.IORef
import Yesod
import Yesod.Static
import Yesod.Default.Config
#ifndef DEVELOPMENT
import Yesod.Default.Util (addStaticContentExternal)
#endif
import Network.HTTP.Conduit (Manager)
-- import qualified Settings
import Settings.Development (development)
import Settings.StaticFiles
import Settings (staticRoot, widgetFile, Extra (..))
#ifndef DEVELOPMENT
import Settings (staticDir)
import Text.Jasmine (minifym)
#endif
import Text.Hamlet (hamletFile)

import Hledger.Web.Options
import Hledger.Data.Types
-- import Hledger.Web.Settings
-- import Hledger.Web.Settings.StaticFiles

-- for addform
import Data.List
import Data.Maybe
import Data.Text as Text (Text,pack,unpack)
import Data.Time.Calendar
import System.FilePath (takeFileName)
#if BLAZE_HTML_0_4
import Text.Blaze (preEscapedString)
#else
import Text.Blaze.Internal (preEscapedString)
#endif
import Text.JSON
import Hledger.Data.Journal
import Hledger.Query
import Hledger hiding (is)
import Hledger.Cli hiding (version)


-- | The site argument for your application. This can be a good place to
-- keep settings and values requiring initialization before your application
-- starts running, such as database connections. Every handler will have
-- access to the data present here.
data App = App
    { settings :: AppConfig DefaultEnv Extra
    , getStatic :: Static -- ^ Settings for static file serving.
    , httpManager :: Manager
      --
    , appOpts    :: WebOpts
    , appJournal :: IORef Journal
    }

-- Set up i18n messages. See the message folder.
mkMessage "App" "messages" "en"

-- This is where we define all of the routes in our application. For a full
-- explanation of the syntax, please see:
-- http://www.yesodweb.com/book/handler
--
-- This function does three things:
--
-- * Creates the route datatype AppRoute. Every valid URL in your
--   application can be represented as a value of this type.
-- * Creates the associated type:
--       type instance Route App = AppRoute
-- * Creates the value resourcesApp which contains information on the
--   resources declared below. This is used in Handler.hs by the call to
--   mkYesodDispatch
--
-- What this function does *not* do is create a YesodSite instance for
-- App. Creating that instance requires all of the handler functions
-- for our application to be in scope. However, the handler functions
-- usually require access to the AppRoute datatype. Therefore, we
-- split these actions into two functions and place them in separate files.
mkYesodData "App" $(parseRoutesFile "config/routes")

-- | A convenience alias.
type AppRoute = Route App

type Form x = Html -> MForm (HandlerT App IO) (FormResult x, Widget)

-- Please see the documentation for the Yesod typeclass. There are a number
-- of settings which can be configured by overriding methods here.
instance Yesod App where
    approot = ApprootMaster $ appRoot . settings

    -- Store session data on the client in encrypted cookies,
    -- default session idle timeout is 120 minutes
    makeSessionBackend _ = fmap Just $ defaultClientSessionBackend
                             (120 * 60)
                             ".hledger-web_client_session_key.aes"

    defaultLayout widget = do
        master <- getYesod
        mmsg <- getMessage

        -- We break up the default layout into two components:
        -- default-layout is the contents of the body tag, and
        -- default-layout-wrapper is the entire page. Since the final
        -- value passed to hamletToRepHtml cannot be a widget, this allows
        -- you to use normal widget features in default-layout.

    --     pc <- widgetToPageContent $ do
    --         $(widgetFile "normalize")
    --         addStylesheet $ StaticR css_bootstrap_css
    --         $(widgetFile "default-layout")
    --     hamletToRepHtml $(hamletFile "templates/default-layout-wrapper.hamlet")

        pc <- widgetToPageContent $ do
            $(widgetFile "normalize")
            addStylesheet $ StaticR css_bootstrap_min_css
             -- load these things early, in HEAD:
            toWidgetHead [hamlet|
                          <script type="text/javascript" src="@{StaticR js_jquery_min_js}"></script>
                          <script type="text/javascript" src="@{StaticR js_typeahead_bundle_min_js}"></script>
                         |]
            addScript $ StaticR js_bootstrap_min_js
            -- addScript $ StaticR js_typeahead_bundle_min_js
            addScript $ StaticR js_jquery_url_js
            addScript $ StaticR js_jquery_cookie_js
            addScript $ StaticR js_jquery_hotkeys_js
            addScript $ StaticR js_jquery_flot_min_js
            addScript $ StaticR js_jquery_flot_time_min_js
            addScript $ StaticR js_jquery_flot_tooltip_min_js
            toWidget [hamlet| \<!--[if lte IE 8]> <script type="text/javascript" src="@{StaticR js_excanvas_min_js}"></script> <![endif]--> |]
            addStylesheet $ StaticR hledger_css
            addScript $ StaticR hledger_js
            $(widgetFile "default-layout")

        staticRootUrl <- (staticRoot . settings) <$> getYesod
        vd@VD{..} <- getViewData
        withUrlRenderer $(hamletFile "templates/default-layout-wrapper.hamlet")

    -- This is done to provide an optimization for serving static files from
    -- a separate domain. Please see the staticRoot setting in Settings.hs
    urlRenderOverride y (StaticR s) =
        Just $ uncurry (joinPath y (Settings.staticRoot $ settings y)) $ renderRoute s
    urlRenderOverride _ _ = Nothing

#ifndef DEVELOPMENT
    -- This function creates static content files in the static folder
    -- and names them based on a hash of their content. This allows
    -- expiration dates to be set far in the future without worry of
    -- users receiving stale content.
    addStaticContent = addStaticContentExternal minifym base64md5 Settings.staticDir (StaticR . flip StaticRoute [])
#endif

    -- Place Javascript at bottom of the body tag so the rest of the page loads first
    jsLoader _ = BottomOfBody

    -- What messages should be logged. The following includes all messages when
    -- in development, and warnings and errors in production.
    shouldLog _ _source level =
        development || level == LevelWarn || level == LevelError

-- This instance is required to use forms. You can modify renderMessage to
-- achieve customized and internationalized form validation messages.
instance RenderMessage App FormMessage where
    renderMessage _ _ = defaultFormMessage

-- | Get the 'Extra' value, used to hold data from the settings.yml file.
getExtra :: Handler Extra
getExtra = fmap (appExtra . settings) getYesod

-- Note: previous versions of the scaffolding included a deliver function to
-- send emails. Unfortunately, there are too many different options for us to
-- give a reasonable default. Instead, the information is available on the
-- wiki:
--
-- https://github.com/yesodweb/yesod/wiki/Sending-email


----------------------------------------------------------------------
-- template and handler utilities

-- view data, used by the add form and handlers

-- | A bundle of data useful for hledger-web request handlers and templates.
data ViewData = VD {
     opts         :: WebOpts    -- ^ the command-line options at startup
    ,here         :: AppRoute   -- ^ the current route
    ,msg          :: Maybe Html -- ^ the current UI message if any, possibly from the current request
    ,today        :: Day        -- ^ today's date (for queries containing relative dates)
    ,j            :: Journal    -- ^ the up-to-date parsed unfiltered journal
    ,q            :: String     -- ^ the current q parameter, the main query expression
    ,m            :: Query    -- ^ a query parsed from the q parameter
    ,qopts        :: [QueryOpt] -- ^ query options parsed from the q parameter
    ,am           :: Query    -- ^ a query parsed from the accounts sidebar query expr ("a" parameter)
    ,aopts        :: [QueryOpt] -- ^ query options parsed from the accounts sidebar query expr
    ,showpostings :: Bool       -- ^ current p parameter, 1 or 0 shows/hides all postings where applicable
    ,showsidebar  :: Bool       -- ^ current showsidebar cookie value
    }

-- | Make a default ViewData, using day 0 as today's date.
nullviewdata :: ViewData
nullviewdata = viewdataWithDateAndParams nulldate "" "" ""

-- | Make a ViewData using the given date and request parameters, and defaults elsewhere.
viewdataWithDateAndParams :: Day -> String -> String -> String -> ViewData
viewdataWithDateAndParams d q a p =
    let (querymatcher,queryopts) = parseQuery d q
        (acctsmatcher,acctsopts) = parseQuery d a
    in VD {
           opts         = defwebopts
          ,j            = nulljournal
          ,here         = RootR
          ,msg          = Nothing
          ,today        = d
          ,q            = q
          ,m            = querymatcher
          ,qopts        = queryopts
          ,am           = acctsmatcher
          ,aopts        = acctsopts
          ,showpostings = p == "1"
          ,showsidebar  = False
          }

-- | Gather data used by handlers and templates in the current request.
getViewData :: Handler ViewData
getViewData = do
  app        <- getYesod
  let opts@WebOpts{cliopts_=copts@CliOpts{reportopts_=ropts}} = appOpts app
  (j, err)   <- getCurrentJournal app copts{reportopts_=ropts{no_elide_=True}}
  msg        <- getMessageOr err
  Just here  <- getCurrentRoute
  today      <- liftIO getCurrentDay
  q          <- getParameterOrNull "q"
  a          <- getParameterOrNull "a"
  p          <- getParameterOrNull "p"
  cookies <- reqCookies <$> getRequest
  let showsidebar = maybe False (=="1") $ lookup "showsidebar" cookies
  return (viewdataWithDateAndParams today q a p){
               opts=opts
              ,msg=msg
              ,here=here
              ,today=today
              ,j=j
              ,showsidebar=showsidebar
              }
    where
      -- | Update our copy of the journal if the file changed. If there is an
      -- error while reloading, keep the old one and return the error, and set a
      -- ui message.
      getCurrentJournal :: App -> CliOpts -> Handler (Journal, Maybe String)
      getCurrentJournal app opts = do
        -- XXX put this inside atomicModifyIORef' for thread safety
        j <- liftIO $ readIORef $ appJournal app
        (jE, changed) <- liftIO $ journalReloadIfChanged opts j
        if not changed
         then return (j,Nothing)
         else case jE of
                Right j' -> do liftIO $ writeIORef (appJournal app) j'
                               return (j',Nothing)
                Left e   -> do setMessage $ "error while reading" {- ++ ": " ++ e-}
                               return (j, Just e)

      -- | Get the named request parameter, or the empty string if not present.
      getParameterOrNull :: String -> Handler String
      getParameterOrNull p = unpack `fmap` fromMaybe "" <$> lookupGetParam (pack p)

-- | Get the message set by the last request, or the newer message provided, if any.
getMessageOr :: Maybe String -> Handler (Maybe Html)
getMessageOr mnewmsg = do
  oldmsg <- getMessage
  return $ maybe oldmsg (Just . toHtml) mnewmsg

-- add form dialog, part of the default template

-- | Add transaction form.
addform :: Text -> ViewData -> HtmlUrl AppRoute
addform _ vd@VD{..} = [hamlet|

<script language="javascript">
  jQuery(document).ready(function() {

    /* set up typeahead fields */

    datesSuggester = new Bloodhound({
      local:#{listToJsonValueObjArrayStr dates},
      limit:100,
      datumTokenizer: function(d) { return [d.value]; },
      queryTokenizer: function(q) { return [q]; }
    });
    datesSuggester.initialize();

    descriptionsSuggester = new Bloodhound({
      local:#{listToJsonValueObjArrayStr descriptions},
      limit:100,
      datumTokenizer: function(d) { return [d.value]; },
      queryTokenizer: function(q) { return [q]; }
    });
    descriptionsSuggester.initialize();

    accountsSuggester = new Bloodhound({
      local:#{listToJsonValueObjArrayStr accts},
      limit:100,
      datumTokenizer: function(d) { return [d.value]; },
      queryTokenizer: function(q) { return [q]; }
      /*
        datumTokenizer: Bloodhound.tokenizers.obj.whitespace('value'),
        datumTokenizer: Bloodhound.tokenizers.whitespace(d.value)
        queryTokenizer: Bloodhound.tokenizers.whitespace
      */
    });
    accountsSuggester.initialize();

    enableTypeahead(jQuery('input#date'), datesSuggester);
    enableTypeahead(jQuery('input#description'), descriptionsSuggester);
    enableTypeahead(jQuery('input#account1, input#account2, input#account3, input#account4'), accountsSuggester);

  });

<form#addform method=POST style="position:relative;">
  <table.form style="width:100%; white-space:nowrap;">
   <tr>
    <td colspan=4>
     <table style="width:100%;">
      <tr#descriptionrow>
       <td>
        <input #date        .typeahead .form-control .input-lg type=text size=15 name=date placeholder="Date" value=#{date}>
       <td>
        <input #description .typeahead .form-control .input-lg type=text size=40 name=description placeholder="Description">
   $forall n <- postingnums
    ^{postingfields vd n}
  <span style="padding-left:2em;">
   <span .small>
     Tab in last field for <a .small href="#" onclick="addformAddPosting(); return false;">more</a> (or ctrl +, ctrl -)
|]
 where
  date = "today" :: String
  dates = ["today","yesterday","tomorrow"] :: [String]
  descriptions = sort $ nub $ map tdescription $ jtxns j
  accts = sort $ journalAccountNamesUsed j
  listToJsonValueObjArrayStr as  = preEscapedString $ encode $ JSArray $ map (\a -> JSObject $ toJSObject [("value", showJSON a)]) as
  numpostings = 4
  postingnums = [1..numpostings]
  postingfields :: ViewData -> Int -> HtmlUrl AppRoute
  postingfields _ n = [hamlet|
<tr .posting>
 <td style="padding-left:2em;">
  <input ##{acctvar} .account-input .typeahead .form-control .input-lg style="width:100%;" type=text name=#{acctvar} placeholder="#{acctph}">
 ^{amtfieldorsubmitbtn}
|]
   where
    islast = n == numpostings
    acctvar = "account" ++ show n
    acctph = "Account " ++ show n
    amtfieldorsubmitbtn
       | not islast = [hamlet|
          <td>
           <input ##{amtvar} .amount-input .form-control .input-lg type=text size=10 name=#{amtvar} placeholder="#{amtph}">
         |]
       | otherwise = [hamlet|
          <td #addbtncell style="text-align:right;">
           <input type=hidden name=action value=add>
           <button type=submit .btn .btn-lg name=submit>add
           $if length files' > 1
            <br>to: ^{journalselect files'}
         |]
       where
        amtvar = "amount" ++ show n
        amtph = "Amount " ++ show n
        files' = [(takeFileName f,s) | (f,s) <- files j]

           -- <button .btn style="font-size:18px;" type=submit title="Add this transaction">Add

journalselect :: [(FilePath,String)] -> HtmlUrl AppRoute
journalselect journalfiles = [hamlet|
<select id=journalselect name=journal onchange="/*journalSelect(event)*/">
 $forall f <- journalfiles
  <option value=#{fst f}>#{fst f}
|]

