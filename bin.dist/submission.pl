#!/usr/bin/env perl
#
# Copyright 1999-2000 Igor Chudov
#
# This file is part of STUMP.
# 
# STUMP is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# STUMP is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with STUMP.  If not, see <https://www.gnu.org/licenses/>.
#
# this script accepts submissions that come to the robomoderator by
# email. It make s a decision whether the submission deserves
# rejection, automatic approval, or is suspicious and should be
# forwarded to human moderators for review.
#
# A decision is essentially a choice of the program that will be
# fed with preprocessed article.
#
# Also note that this script fixes common problems and mistakes in
# newsreaders, newsservers, and users. Even though we have no
# obligation to fix these problems, people get really disappointed
# if we outright reject their bogus messages, because these
# people often have no control over how the posts get delivered to us.
#
# This script supports notion of blacklisting and list of
# preapproved persons. As the names imply, we reject all submissions
# from blacklisted posters and automatically approve all messages submitted
# by preapproved posters (provided that their posts meet other criteria
# imposed by the robomoderator.
#
# For an automatic rejection, it gives a main "reason" for rejection
#
#Currently supported list of reasons: 
#
#	- crosspost
#	- abuse
#	- harassing
#	- offtopic

# get the directory where robomod is residing
$MNG_ROOT = $ENV{'MNG_ROOT'} || die "Root dir for moderation not specified";

# common library
require "$MNG_ROOT/bin/robomod.pl";

# max allowed number of newsgroups in crossposts
# change it if you want, but 5 is really good.
$maxNewsgroups = $ENV{'MAX_CROSSPOSTS'} || 5; 

# should we ALWAYS require preapproved posters to sign their submissions
# with PGP? Turn it on in the `etc/modenv' if you suffer from numerous
# forgeries in the names of preapproved posters.
$PGPCheckPreapproved = $ENV{ "WHITELIST_MUST_SIGN" } eq "YES";

# So, what newsgroup I am moderating?
$Newsgroup = $ENV{'NEWSGROUP'};

# as the name implies. ATTENTION: $TMP must be mode 700!!!
$TmpFile = "$ENV{'TMP'}/submission.$$";

# how do we treat suspicious articles?
$Command_Suspicious = "formail -b -a \"Newsgroups: $Newsgroup\" " .
                      "| stump.pl suspicious.pl";
# approved
$Command_Approve = "processApproved robomod";
# rejected
$Command_Reject  = "processRejected robomod";

# location of blacklist
$badGuys = "bad.guys.list";

# location of preapproved list
$goodGuys = "good.guys.list";

# words that trigger robomod to mark messages suspicious, even 
# when the message comes from a preapproved person.
$badWords = "bad.words.list";

# list of people who want all their submissions to be signed
$PGPMustList = "pgp.must.list";

# set PMUSER to Internal. Will be used by `suspicious' script.
$ENV{'PMUSER'} = $ENV{'PMUSER_INTERNAL'};


######################################################################
# Filter rules
# checks if all is OK with newsgroups.
# what's not OK: 
#   1. Megacrossposts
#   2. Crossposts to other moderated groups
#   3. Control messages (currently)
#
sub checkNewsgroups {

  # We have not implemented Control: yet...
  if( $Control ) {
print STDERR "CONTROL message - rejected\n";
    return "$Command_Reject crosspost You posted a Control message which " .
           "is not allowed.";
  }

  if( $#newsgroups >= $maxNewsgroups ) {
print STDERR "Too many newsgroups\n";
    return "$Command_Reject crosspost Too many newsgroups, " .
           "$maxNewsgroups is maximum.";
  }

  local( $good ) = 0;

  for( $i = 0; $i <= $#newsgroups; $i++ ) {

    if( $newsgroups[$i] eq $Newsgroup ) {
      $good = 1;
      next;
    }

    if( $NewsgroupsDB{$newsgroups[$i]} eq 'm' && 
        $newsgroups[$i] ne $Newsgroup) {
print STDERR "posting to ANOTHER moderated newsgroups\n";
      return "$Command_Reject crosspost You crossposted to another " .
             "moderated newsgroup.";
    }

  }

  if( !$good ) { # Some fool forgot to list the moderated newsgroup
                 # in the Newsgroups
    $Newsgroups .= ",$Newsgroup";
    if( $#newsgroups + 1 >= $maxNewsgroups ) {
print STDERR "Too many newsgroups\n";
      return "$Command_Reject crosspost Too many newsgroups, " .
             "$maxNewsgroups is maximum.";
    }
    $BadNewsgroupsHeader ||= 'nogroup';
  }

  return 0;
}

###################################################################### checkAck
# checks if poster needs acknowledgment of receipt
#
sub checkAck {
  if( &nameIsInList( $From, "noack.list" ) ) {
    $needAck = "no";
  } else {
    $needAck = "yes";
  }
}

################################################################### checkPGP
# checks PGP sig IF REQUIRED
#
# we can reject a post if
#
#   1. A post must be signed accordinng to rules OR
#   2. A post is signed but verification fails.
#
# Note that we set From: to the user ID in the PGP signature
# if a signature is present. It allows for identification of trolls
# and for preventing subtle forgeries.
#
sub checkPGP {

  local( $FromSig ) = `verifySignature < $TmpFile`; chop( $FromSig );
  local( $good ) = $? == 0;

print STDERR "FromSig = $FromSig, good = $good\n" if $FromSig;

  if( !$good ) {
    return "$Command_Reject signature Your PGP signature does NOT match, or is not in our keyring";
  }

  if( &nameIsInList( $From, $PGPMustList ) ||
      ($PGPCheckPreapproved && &nameIsInList($From, $goodGuys) ) ) {
    if( $FromSig eq "" ) {
      return "$Command_Reject signature You are REQUIRED to sign your posts.";
    } 
  }

  if( $FromSig ) {
    $X_Origin = $From;
    $From = "From: $FromSig";
    $ReplyTo = $From;
  }

  # else nothing to do
  return 0;
}

################################################################ checkCharter
# checks charter calling conforms_charter
#
sub checkCharter {
  open( VERIFY, "|conforms_charter" );
  print VERIFY $Body;
  close( VERIFY );

  return $? == 0;
}

################################################################### Filter
# contains all filtering rules. calls subroutines above.
sub Filter {


  local( $response );

  @newsgroups = split( /,/, $Newsgroups );

  return "Command_Reject charter We do not allow any control and " .
         "cancel messages. contact newsgroup administrator" 
    if( $Control );

  if( $response = &checkNewsgroups() ) {
      return $response;
  }

  if( $paranoid_pgp ) {
    if( $response = &checkPGP() ) {
        return $response;
    }
  }

  if( &nameIsInList( $From, $badGuys ) ) {
    return "$Command_Reject abuse";
  }

  # note that if even a preapproved person uses "BAD words" (that is
  # words from a special list), his/her message will be marked
  # "suspicious" and will be forwarded to a humen mod for review.
  # As an example of a bad word may be "MAKE MONEY FAST - IT REALLY WORKS!!!"
  #
  if( $badWord = &nameIsInList( $Body, $badWords ) ) {
print STDERR "BAD WORD $badWord FOUND!!!\n";
    return $Command_Suspicious; # messages from approved guys MAY be 
                         # suspicious if they write about
                         # homosexual forgers
  }

  # checking for charter-specific restrictions
  if( !&checkCharter || ($Encoding =~ "base64") ) {
    return "$Command_Reject charter you sent a " .
           "binary encoded file which is not allowed.";
  }

  # Checking preapproved list
  if( &nameIsInList( $From, $goodGuys ) ) {
  local( $from ) = $From; $from =~ s/^From: //i;
print STDERR "$from is a PREAPPROVED person\n";
    return $Command_Approve;
  }

  # Here I may put some more rules...

  return $Command_Suspicious;
}

######################################################################
# set defaults
sub setDefaults {
  if( !$Newsgroups ) {
    $Newsgroups = $ENV{ "NEWSGROUP" } || die "No default newsgroup";
  }
}

################################################################# ignoreHeader
# some of the header fields present in emails must be ignored.
#
sub ignoreHeader {
  local( $header ) = pop( @_ );

#  return 1 if( $header =~ /^Control:/i );
  return 1 if( $header =~ /^Expires:/i );
  return 1 if( $header =~ /^Supersedes:/i );
  return 1 if( $header =~ /^Precedence:/i );
  return 1 if( $header =~ /^Apparently-To:/i );
  return 1 if( $header =~ /^Date:/i );
  return 1 if( $header =~ /^Expires:/i );
  return 1 if( $header =~ /^Distribution:/i );
  return 1 if( $header =~ /^Path:/i );
  return 1 if( $header =~ /^NNTP-Posting-Host:/i );
  return 1 if( $header =~ /^Xref:/i );
  return 1 if( $header =~ /^Status:/i );
  return 1 if( $header =~ /^Lines:/i );
  return 1 if( $header =~ /^Apparently-To:/i );
  return 1 if( $header =~ /^Cc:/i );
  return 1 if( $header =~ /^Sender:/i );
  return 1 if( $header =~ /^In-Reply-To:/i );
  return 1 if( $header =~ /^Originator:/i );
  return 1 if( $header =~ /^X-Trace:/i );

  return 0;
}


######################################################################
# Getting data
# 
# reads message, sets variables describing header fields
#
# it also tries to "fix" the problem with old newsservers (B-News I think)
# when they try to "wrap" a submission in one more layer of meaningless
# headers. It is recognized by STUPID presense of TWO identical To: 
# fields.
#

sub readMessage {

  open( TMPFILE, "> $TmpFile" );

  $IsBody = 0;
  my $ignoring = 0;
  
  while( <> ) {
    $Body .= $_;

# Ignore headers that cause trouble. Ignore their continuation lines too.
    if( !$IsBody && &ignoreHeader( $_ ) ) {
      $ignoring = 1;
      next;
    } elsif (!$IsBody && $ignoring && /^\s/) {
      next
    } else {
      $ignoring = 0;
    }

    print TMPFILE;
  
    chop;
  
    if( /^$/ ) {
      if( !$Subject && $From =~ /news\@/) {
        $BadNewsserver = 1;
      }

      if( $BadNewsserver ) { # just ignore the outer layer of headers
        $To = 0;
      } else {
        $IsBody = 1;
      }
    }
  
    if( !$IsBody ) {
  
      if( /^Newsgroups: / ) { # set Newsgroups, remove spaces
        $Newsgroups = $_;
        $Newsgroups =~ s/^Newsgroups: //i;
        $Newsgroups =~ s/ //g; # some fools put spaces in list of newsgroups
      } elsif( /^Subject: / ) {
        $Subject = $_;
      } elsif( /^From: / ) {
        $From = $_;
      } elsif( /^To: / ) {
        if( $To && ($To eq $_)) { 
          # Old & crappy news servers that wrap submissions with one more
          # layer of headers. For them, I simply ignore the outer
          # headers. These (at least I think) submissions may be
          # recognized by TWO idiotic To: header fields.
print STDERR "BAD NEWSSERVER\n";
          $BadNewsserver = 1;
        }
        $To = $_;
      } elsif( /^Path: / ) {
        $Path = $_;
      } elsif( /^Keywords: / ) {
        $Keywords = $_;
      } elsif( /^Summary: / ) {
        $Summary = $_;
      } elsif( /^Control: / ) {
        $Control = $_;
      } elsif( /^Message-ID: / ) {
        $Message_ID = $_;
      } elsif ( /^Content-Transfer-Encoding: / ) {
        $Encoding = $_;
        $Encoding =~ s/^Content-Transfer-Encoding: //;
      }
  
    }
  }

  close( TMPFILE );
}

###################################################################### work
# all main work is done here

######################################################################
# read the thing
&readMessage();

if( !$Newsgroups ) {
  # Record issues with Newsgroups header to pass to moderator/Webstump
  if ( !defined($Newsgroups)) {
    $BadNewsgroupsHeader = 'missing';
  } else {
    $BadNewsgroupsHeader = 'empty';
  }
  $Newsgroups = $Newsgroup;
}

######################################################################
# process acks
&checkAck;
$Command_Suspicious .= " $needAck";

######################################################################
# set defaults
&setDefaults();

######################################################################
# Check

$command = &Filter;

######################################################################
# process
print STDERR "command = $command\n";

open( COMMAND, "| $command" );
open( TMPFILE, "$TmpFile" ) || die "cant open tmpfile";


  $IsBody = 0;

  while( <TMPFILE> ) {
    if( $BadNewsserver && !(/^$/) ) {
      next;
    }

    if( $BadNewsserver && /^$/ ) {
      $BadNewsserver = 0;
      next;
    }

    if( /^$/ ) {
      $IsBody = 1;
    }

    if( /^From / ) {
      print COMMAND;
      print COMMAND "X-Origin: $X_Origin, $_" if $X_Origin;
      print STDERR "Subject =`$Subject'\n";
      print COMMAND "Subject: No subject given\n" if !$Subject;
      print COMMAND "X-STUMP-Warning: Newsgroups header $BadNewsgroupsHeader\n" if $BadNewsgroupsHeader;
      # nothing
    } elsif( /^From: / && !$IsBody) {
      next if $FromWasUsed;

      $FromWasUsed = 1; # note that some crappy remailers have several
                        # "From: " fields. We really do NOT want two
                        # "From: " to go to headers!

      if( $From ) {
        print COMMAND "$From\n";
        $From = "";
      } else {
        print COMMAND;
      }
    } elsif( /^Newsgroups: / && !$IsBody ) {
      print COMMAND "Newsgroups: $Newsgroups\n";
    } else {
      print COMMAND;
    }
  }

close( TMPFILE );
close( COMMAND );

################################################################## Archiving
# archive
open( COMMAND, "| procmail -f- $MNG_ROOT/etc/procmail/save-incoming" );

print COMMAND $Body;

close( COMMAND );

unlink( $TmpFile );
