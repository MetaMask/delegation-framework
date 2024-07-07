// SPDX-License-Identifier: MIT AND Apache-2.0

pragma solidity 0.8.23;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract BasicCF721 is ERC721, Ownable2Step {
    ////////////////////////////// State //////////////////////////////

    uint256 public tokenId;
    mapping(uint256 => string) public tokenURIs;
    string public baseURI;

    ////////////////////////////// Constructor  //////////////////////////////

    constructor(
        address _owner,
        string memory _name,
        string memory _symbol,
        string memory _baseUri
    )
        ERC721(_name, _symbol)
        Ownable(_owner)
    {
        baseURI = _baseUri;
    }

    ////////////////////////////// External Methods //////////////////////////////

    function setBaseURI(string memory _baseUri) external onlyOwner {
        baseURI = _baseUri;
    }

    function mint(address _to) public onlyOwner {
        _mint(_to, tokenId);
        tokenId++;
    }

    function selfMint() public onlyOwner {
        mint(msg.sender);
    }

    function mintWithMetadata(address _to, string memory _metadataUri) public onlyOwner {
        tokenURIs[tokenId] = _metadataUri;
        mint(_to);
    }

    function tokenURI(uint256 _tokenId) public view virtual override returns (string memory) {
        return tokenURIs[_tokenId];
    }

    ////////////////////////////// Internal Methods //////////////////////////////

    function _baseURI() internal view virtual override returns (string memory) {
        return baseURI;
    }
}
