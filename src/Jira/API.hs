{-# LANGUAGE OverloadedStrings #-}

module Jira.API ( createIssue
                , getIssue
                , deleteIssue
                , assignIssue
                , startProgress
                , resolveIssue
                , closeIssue
                , reopenIssue
                , makeIssueTransition
                , getIssueTransitions
                , searchIssues'

                , getJson
                , getJson'
                , postJson
                , putJson
                , postJsonRaw
                , putJsonRaw
                , getRaw
                , getRaw'
                , deleteRaw
                , postRaw
                , putRaw
                , sendRequest
                , urlWithPath

                , module Jira.API.Types
                , module Jira.API.Authentication
                ) where

import           Jira.API.Authentication
import           Jira.API.Types

import           Control.Applicative
import           Control.Lens            hiding ((.=))
import           Control.Monad.Except
import           Data.Aeson
import           Data.Aeson.Lens
import qualified Data.CaseInsensitive    as CI
import           Data.List
import           Data.String.Conversions
import           Network.HTTP.Client

import qualified Data.ByteString         as BS
import qualified Data.ByteString.Lazy    as LBS

type QueryString = [(BS.ByteString, Maybe BS.ByteString)]

-- Typed API Layer

createIssue :: IssueCreationData -> JiraM String
createIssue = takeKey <=< postJson "/issue"
  where takeKey :: Value -> JiraM String
        takeKey v = tryMaybe (keyNotFound v) $ v ^? key "key" . asString
        keyNotFound v = JsonFailure $ "Key not found in JSON: " ++ cs (encode v)
        asString = _String . to cs

getIssue :: IssueIdentifier -> JiraM Issue
getIssue = getJson' . issuePath

deleteIssue :: IssueIdentifier -> JiraM ()
deleteIssue = deleteRaw . issuePath

assignIssue :: IssueIdentifier -> Assignee -> JiraM ()
assignIssue issue assignee = void $
  putJsonRaw (issuePath issue ++ "/assignee") assignee

startProgress :: IssueIdentifier -> JiraM ()
startProgress issue = makeIssueTransition issue (TransitionName "Start Progress")

resolveIssue :: IssueIdentifier -> JiraM ()
resolveIssue issue = makeIssueTransition issue (TransitionName "Resolve Issue")

closeIssue :: IssueIdentifier -> JiraM ()
closeIssue issue = makeIssueTransition issue (TransitionName "Close Issue")

reopenIssue :: IssueIdentifier -> JiraM ()
reopenIssue issue = makeIssueTransition issue (TransitionName "Reopen Issue")

searchIssues' :: String -> JiraM [Issue]
searchIssues' jql = do
  (IssuesResponse issues) <- getJson "search" [("jql", Just (cs jql))]
  return issues

makeIssueTransition :: IssueIdentifier -> TransitionIdentifier -> JiraM ()
makeIssueTransition issue (TransitionId tid) = void $
  postJsonRaw (issuePath issue ++ "/transitions") $
    object ["transition" .= TransitionIdRequest tid]
makeIssueTransition issue (TransitionName tname) = void $ do
  transitions <- getIssueTransitions issue
  case find nameMatches transitions of
    Nothing -> throwError $ JsonFailure $ "Issue transition is not available: " ++ tname
    Just t  -> makeIssueTransition issue $ t^.transitionId.to TransitionId
  where
    nameMatches t = CI.mk tname == t^.transitionName.to CI.mk

getIssueTransitions :: IssueIdentifier -> JiraM [Transition]
getIssueTransitions issue = do
  (TransitionsResponse ts) <- getJson' $ issuePath issue ++ "/transitions"
  return ts

issuePath :: IssueIdentifier -> String
issuePath issue = "/issue/" ++ urlId issue

-- Generic JSON API Layer

getJson :: FromJSON a => String -> QueryString -> JiraM a
getJson url = decodeJson <=< getRaw url

getJson' :: FromJSON a => String -> JiraM a
getJson' url = getJson url []

postJson :: (FromJSON a, ToJSON p) => String -> p -> JiraM a
postJson urlPath = decodeJson <=< postJsonRaw urlPath

putJson :: (FromJSON a, ToJSON p) => String -> p -> JiraM a
putJson urlPath = decodeJson <=< putJsonRaw urlPath

decodeJson :: FromJSON a => LBS.ByteString -> JiraM a
decodeJson rawJson = case decode rawJson of
   Nothing -> throwError $ JsonFailure (cs rawJson)
   Just v  -> return v

postJsonRaw :: ToJSON a => String -> a -> JiraM LBS.ByteString
postJsonRaw urlPath = postRaw urlPath . encode

putJsonRaw :: ToJSON a => String -> a -> JiraM LBS.ByteString
putJsonRaw urlPath = putRaw urlPath . encode

-- Raw API Layer

getRaw :: String -> QueryString -> JiraM LBS.ByteString
getRaw url qs = raw "GET" url (setQueryString qs)

getRaw' :: String -> JiraM LBS.ByteString
getRaw' url = getRaw url []

deleteRaw :: String -> JiraM ()
deleteRaw = void . raw' "DELETE"

postRaw :: String -> LBS.ByteString -> JiraM LBS.ByteString
postRaw urlPath payload = raw "POST" urlPath (addJsonPayload payload)

putRaw :: String -> LBS.ByteString -> JiraM LBS.ByteString
putRaw urlPath payload = raw "PUT" urlPath (addJsonPayload payload)

raw' :: String -> String -> JiraM LBS.ByteString
raw' httpMethod urlPath = raw httpMethod urlPath id

raw :: String -> String -> (Request -> Request) -> JiraM LBS.ByteString
raw httpMethod urlPath transformRequest = do
  url         <- urlWithPath urlPath
  initRequest <- parseUrl url
  let request = transformRequest initRequest { method = cs httpMethod }
  responseBody <$> sendRequest request

sendRequest :: Request -> JiraM (Response LBS.ByteString)
sendRequest request = do
  config <- getConfig
  manager <- getManager
  authedRequest <- applyAuth config request
  tryIO $ httpLbs authedRequest manager

-- Helpers

urlWithPath :: String -> JiraM String
urlWithPath urlPath = view baseUrl <$$> (++ "/rest/api/2/" ++ removeFirstSlash urlPath)
  where removeFirstSlash ('/':xs) = xs
        removeFirstSlash s        = s
        (<$$>) = flip (<$>)

addJsonPayload :: LBS.ByteString -> Request -> Request
addJsonPayload payload r =
  r { requestBody    = RequestBodyLBS payload
    , requestHeaders = [("Content-Type", "application/json;charset=utf-8")]
    }