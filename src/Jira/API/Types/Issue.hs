{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE IncoherentInstances  #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# LANGUAGE UndecidableInstances #-}

module Jira.API.Types.Issue where

import           Jira.API.Types.Classes
import           Jira.API.Types.IssueType
import           Jira.API.Types.Project
import           Jira.API.Types.Status
import           Jira.API.Types.User

import           Control.Applicative
import           Control.Lens             (makeLenses, non, to, (^.))
import           Data.Aeson
import           Data.List.Split
import           Data.Maybe
import           Data.Monoid

class IssueIdentifier a where
  issueId :: a -> String

instance (IssueIdentifier i) => UrlIdentifier i where
  urlId = issueId

newtype IssueId = IssueId Int deriving (Show, Eq)

instance IssueIdentifier IssueId where
  issueId (IssueId n) = show n

newtype IssueNumber = IssueNumber Int deriving (Show, Eq)

instance IssueIdentifier IssueNumber where
  issueId (IssueNumber n) = show n

data IssueKey = IssueKey ProjectKey IssueNumber deriving (Eq)

instance Show IssueKey where
  show (IssueKey key (IssueNumber n)) =
    key ++ "-" ++ show n

instance IssueIdentifier IssueKey where
  issueId = show

data IssueCreationData = IssueCreationData { _icProject :: ProjectIdentifier
                                           , _icType    :: IssueTypeIdentifier
                                           , _icSummary :: String
                                           } deriving (Show, Eq)

makeLenses ''IssueCreationData

instance ToJSON IssueCreationData where
 toJSON issueCreation = object [ "fields" .= fields ]
   where fields = object [ "project"   .= (issueCreation^.icProject)
                         , "issuetype" .= (issueCreation^.icType)
                         , "summary"   .= (issueCreation^.icSummary)
                         ]

data Issue = Issue { _iId          :: String
                   , _iKey         :: String
                   , _iType        :: IssueType
                   , _iProject     :: Project
                   , _iSummary     :: String
                   , _iDescription :: Maybe String
                   , _iAssignee    :: Maybe User
                   , _iReporter    :: User
                   , _iStatus      :: Status
                   }

makeLenses ''Issue

instance Show Issue where
  show i = unlines
    [ "Id: " ++ i^.iId
    , "Key: " ++ i^.iKey
    , "Project: " ++ i^.iProject.pName
    , "Type: " ++ i^.iType.itName
    , "Summary: " ++ i^.iSummary
    , "Description: " ++ i^.iDescription.non "(No description)"
    , "Assignee: " ++ i^.iAssignee.to (maybe "Unassigned" show)
    , "Reporter: " ++ i^.iReporter.to show
    , "Status: " ++ i^.iStatus.to show
    ]

instance Eq Issue where
  a == b = (a^.iId) == (b^.iId)

instance Ord Issue where
  compare a b = fromMaybe compareKeys $ do
    (prefix, n)  <- a^.iKey.to splitKey
    (prefix', m) <- b^.iKey.to splitKey
    return $ prefix `compare` prefix' <> n `compare` m
    where
      compareKeys :: Ordering
      compareKeys = (a^.iKey) `compare` (b^.iKey)

      splitKey :: String -> Maybe (String, Int)
      splitKey key = case splitOn "-" key of
        [prefix, n] -> Just (prefix, read n)
        _           -> Nothing

instance FromJSON Issue where
  parseJSON = withObject "Expected object" $ \o -> do
    fields <- o .: "fields"
    Issue <$> o .: "id"
          <*> o .: "key"
          <*> fields .: "issuetype"
          <*> fields .: "project"
          <*> fields .: "summary"
          <*> fields .: "description"
          <*> fields .: "assignee"
          <*> fields .: "reporter"
          <*> fields .: "status"

newtype IssuesResponse = IssuesResponse [Issue]

instance FromJSON IssuesResponse where
  parseJSON = withObject "Expected object" $ \o ->
    IssuesResponse <$> o .: "issues"

newtype CreateIssueMetadata = CreateIssueMetadata [(Project, [IssueType])]
                              deriving (Show, Eq)

instance FromJSON CreateIssueMetadata where
  parseJSON = withObject "Expected object" $ \o -> do
    projects <- o .: "projects"
    CreateIssueMetadata <$> mapM parseProject projects
    where
      parseProject po = do
        issueType <- po .: "issuetypes"
        project   <- parseJSON (Object po)
        return (project, issueType)
