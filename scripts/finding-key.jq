# finding_key — the one fingerprint of a review finding: the sweep queue keeps a defect
# once by it, and the review step refuses to post one twice by it. A class is keyed on
# the class alone; anything else on its file and the first twelve words of its summary,
# ignoring the line (it moves between rounds), case, spacing and punctuation.
def _fk_words: ascii_downcase | [scan("[a-z0-9]+")];
def finding_key:
  if ((.class // "") | tostring | length) > 0
  then "class|" + ((.class | tostring | _fk_words) | join(" "))
  else ((.file // "") | tostring | sub("^\\./"; "") | sub(":[0-9]+$"; "") | ascii_downcase)
       + "|" + ((.summary // "") | tostring | _fk_words | .[0:12] | join(" "))
  end;
